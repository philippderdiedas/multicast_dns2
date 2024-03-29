// Copyright 2018 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:multicast_dns2/src/constants.dart';
import 'package:multicast_dns2/src/packet.dart';

// TODO(dnfield): Probably should go with a real hashing function here
// when https://github.com/dart-lang/sdk/issues/11617 is figured out.
const int _seedHashPrime = 2166136261;
const int _multipleHashPrime = 16777619;

int _combineHash(int current, int hash) =>
    (current & _multipleHashPrime) ^ hash;

int _hashValues(List<int> values) {
  assert(values != null);
  assert(values.isNotEmpty);

  return values.fold(
    _seedHashPrime,
    (int current, int next) => _combineHash(current, next),
  );
}

/// Enumeration of support resource record types.
class ResourceRecordType {
  // This class is intended to be used as a namespace, and should not be
  // extended directly.
  factory ResourceRecordType._() => null;

  /// An IPv4 Address record, also known as an "A" record. It has a value of 1.
  static const int addressIPv4 = 1;

  /// An IPv6 Address record, also known as an "AAAA" record.  It has a vaule of
  /// 28.
  static const int addressIPv6 = 28;

  /// An IP Address reverse map record, also known as a "PTR" recored. It has a
  /// value of 12.
  static const int serverPointer = 12;

  /// An available service record, also known as an "SRV" record.  It has a
  /// value of 33.
  static const int service = 33;

  /// A text record, also known as a "TXT" record.  It has a value of 16.
  static const int text = 16;

  // TODO(dnfield): Support ANY in some meaningful way.  Might be server only.
  // /// A query for all records of all types known to the name server.
  // static const int any = 255;

  /// Checks that a given int is a valid ResourceRecordType.
  ///
  /// This method is intended to be called only from an `assert()`.
  static bool debugAssertValid(int resourceRecordType) {
    return resourceRecordType == addressIPv4 ||
        resourceRecordType == addressIPv6 ||
        resourceRecordType == serverPointer ||
        resourceRecordType == service ||
        resourceRecordType == text;
  }

  /// Prints a debug-friendly version of the resource record type value.
  static String toDebugString(int resourceRecordType) {
    switch (resourceRecordType) {
      case addressIPv4:
        return 'A (IPv4 Address)';
      case addressIPv6:
        return 'AAAA (IPv6 Address)';
      case serverPointer:
        return 'PTR (Domain Name Pointer)';
      case service:
        return 'SRV (Service record)';
      case text:
        return 'TXT (Text)';
    }
    return 'Unknown ($resourceRecordType)';
  }
}

/// Represents a DNS query.
class ResourceRecordQuery {
  /// Creates a new ResourceRecordQuery.
  ///
  /// Most callers should prefer one of the named constructors.
  ResourceRecordQuery(
    this.resourceRecordType,
    this.fullyQualifiedName,
    this.questionType,
  )   : assert(fullyQualifiedName != null),
        assert(ResourceRecordType.debugAssertValid(resourceRecordType));

  /// An A (IPv4) query.
  ResourceRecordQuery.addressIPv4(
    String name, {
    bool isMulticast = true,
  }) : this(
          ResourceRecordType.addressIPv4,
          name,
          isMulticast ? QuestionType.multicast : QuestionType.unicast,
        );

  /// An AAAA (IPv6) query.
  ResourceRecordQuery.addressIPv6(
    String name, {
    bool isMulticast = true,
  }) : this(
          ResourceRecordType.addressIPv6,
          name,
          isMulticast ? QuestionType.multicast : QuestionType.unicast,
        );

  /// A PTR (Server pointer) query.
  ResourceRecordQuery.serverPointer(
    String name, {
    bool isMulticast = true,
  }) : this(
          ResourceRecordType.serverPointer,
          name,
          isMulticast ? QuestionType.multicast : QuestionType.unicast,
        );

  /// An SRV (Service) query.
  ResourceRecordQuery.service(
    String name, {
    bool isMulticast = true,
  }) : this(
          ResourceRecordType.service,
          name,
          isMulticast ? QuestionType.multicast : QuestionType.unicast,
        );

  /// A TXT (Text record) query.
  ResourceRecordQuery.text(
    String name, {
    bool isMulticast = true,
  }) : this(
          ResourceRecordType.text,
          name,
          isMulticast ? QuestionType.multicast : QuestionType.unicast,
        );

  /// Tye type of resource record - one of [ResourceRecordType]'s values.
  final int resourceRecordType;

  /// The Fully Qualified Domain Name associated with the request.
  final String fullyQualifiedName;

  /// The [QuestionType], i.e. multicast or unicast.
  final int questionType;

  /// Convenience accessor to determine whether the question type is multicast.
  bool get isMulticast => questionType == QuestionType.multicast;

  /// Convenience accessor to determine whether the question type is unicast.
  bool get isUnicast => questionType == QuestionType.unicast;

  /// Encodes this query to the raw wire format.
  List<int> encode() {
    return encodeMDnsQuery(
      fullyQualifiedName,
      type: resourceRecordType,
      multicast: isMulticast,
    );
  }

  @override
  int get hashCode => _hashValues(
      <int>[resourceRecordType, fullyQualifiedName.hashCode, questionType]);

  @override
  bool operator ==(Object other) {
    return other is ResourceRecordQuery &&
        other.resourceRecordType == resourceRecordType &&
        other.fullyQualifiedName == fullyQualifiedName &&
        other.questionType == questionType;
  }

  @override
  String toString() =>
      '$runtimeType{$fullyQualifiedName, type: ${ResourceRecordType.toDebugString(resourceRecordType)}, isMulticast: $isMulticast}';
}

/// Base implementation of DNS resource records (RRs).
abstract class ResourceRecord {
  /// Creates a new ResourceRecord.
  const ResourceRecord(this.resourceRecordType, this.name, this.validUntil)
      : assert(name != null);

  /// The FQDN for this record.
  final String name;

  /// The epoch time at which point this record is valid for in the cache.
  final int validUntil;

  /// The raw resource record value.  See [ResourceRecordType] for supported values.
  final int resourceRecordType;

  String get _additionalInfo;

  @override
  String toString() =>
      '$runtimeType{$name, validUntil: ${DateTime.fromMillisecondsSinceEpoch(validUntil ?? 0)}, $_additionalInfo}';

  @override
  bool operator ==(Object other) {
    return other.runtimeType == runtimeType && _equals(other);
  }

  @protected
  bool _equals(ResourceRecord other) {
    return other.name == name &&
        other.validUntil == validUntil &&
        other.resourceRecordType == resourceRecordType;
  }

  @override
  int get hashCode {
    return _hashValues(<int>[
      name.hashCode,
      validUntil.hashCode,
      resourceRecordType.hashCode,
      _hashCode,
    ]);
  }

  // Subclasses of this class should use _hashValues to create a hash code
  // that will then get hashed in with the common values on this class.
  @protected
  int get _hashCode;

  /// Low level method for encoding this record into an mDNS packet.
  ///
  /// Subclasses should provide the packet format of their encapsulated data
  /// into a `Uint8List`, which could then be used to write a pakcet to send
  /// as a response for this record type.
  Uint8List encodeResponseRecord();
}

/// A Service Pointer for reverse mapping an IP address (DNS "PTR").
class PtrResourceRecord extends ResourceRecord {
  /// Creates a new PtrResourceRecord.
  PtrResourceRecord(
    String name,
    int validUntil, {
    @required this.domainName,
  })  : assert(domainName != null),
        super(ResourceRecordType.serverPointer, name, validUntil);

  /// The FQDN for this record.
  final String domainName;

  @override
  String get _additionalInfo => 'domainName: $domainName';

  @override
  bool _equals(ResourceRecord other) {
    return other is PtrResourceRecord &&
        other.domainName == domainName &&
        super._equals(other);
  }

  @override
  int get _hashCode => _combineHash(_seedHashPrime, domainName.hashCode);

  @override
  Uint8List encodeResponseRecord() {
    return Uint8List.fromList(utf8.encode(domainName));
  }
}

/// An IP Address record for IPv4 (DNS "A") or IPv6 (DNS "AAAA") records.
class IPAddressResourceRecord extends ResourceRecord {
  /// Creates a new IPAddressResourceRecord.
  IPAddressResourceRecord(
    String name,
    int validUntil, {
    @required this.address,
  }) : super(
            address.type == InternetAddressType.IPv4
                ? ResourceRecordType.addressIPv4
                : ResourceRecordType.addressIPv6,
            name,
            validUntil);

  /// The [InternetAddress] for this record.
  final InternetAddress address;

  @override
  String get _additionalInfo => 'address: $address';

  @override
  bool _equals(ResourceRecord other) {
    return other is IPAddressResourceRecord && other.address == address;
  }

  @override
  int get _hashCode => _combineHash(_seedHashPrime, address.hashCode);

  @override
  Uint8List encodeResponseRecord() {
    return Uint8List.fromList(address.rawAddress);
  }
}

/// A Service record, capturing a host target and port (DNS "SRV").
class SrvResourceRecord extends ResourceRecord {
  /// Creates a new service record.
  SrvResourceRecord(
    String name,
    int validUntil, {
    @required this.target,
    @required this.port,
    @required this.priority,
    @required this.weight,
  })  : assert(target != null),
        assert(port != null),
        assert(priority != null),
        assert(weight != null),
        super(ResourceRecordType.service, name, validUntil);

  /// The hostname for this record.
  final String target;

  /// The port for this record.
  final int port;

  /// The relative priority of this service.
  final int priority;

  /// The weight (used when multiple services have the same priority).
  final int weight;

  @override
  String get _additionalInfo =>
      'target: $target, port: $port, priority: $priority, weight: $weight';

  @override
  bool _equals(ResourceRecord other) {
    return other is SrvResourceRecord &&
        other.target == target &&
        other.port == port &&
        other.priority == priority &&
        other.weight == weight;
  }

  @override
  int get _hashCode => _hashValues(<int>[
        target.hashCode,
        port.hashCode,
        priority.hashCode,
        weight.hashCode,
      ]);

  @override
  Uint8List encodeResponseRecord() {
    final List<int> data = utf8.encode(target);
    final Uint8List result = Uint8List(data.length + 7);
    final ByteData resultData = ByteData.view(result.buffer);
    resultData.setUint16(0, priority);
    resultData.setUint16(2, weight);
    resultData.setUint16(4, port);
    result[6] = data.length;
    return result..setRange(7, data.length, data);
  }
}

/// A Text record, contianing additional textual data (DNS "TXT").
class TxtResourceRecord extends ResourceRecord {
  /// Creates a new text record.
  TxtResourceRecord(
    String name,
    int validUntil, {
    @required this.text,
  })  : assert(text != null),
        super(ResourceRecordType.text, name, validUntil);

  /// The raw text from this record.
  final String text;

  @override
  String get _additionalInfo => 'text: $text';

  @override
  bool _equals(ResourceRecord other) {
    return other is TxtResourceRecord && other.text == text;
  }

  @override
  int get _hashCode => _combineHash(_seedHashPrime, text.hashCode);

  @override
  Uint8List encodeResponseRecord() {
    return Uint8List.fromList(utf8.encode(text));
  }
}
