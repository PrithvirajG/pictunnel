/// Certificate pinning for the Flutter browse client (P§6.3).
///
/// A chain the system trusts never reaches this code (dart:io accepts it).
/// For anything else, the leaf's SPKI SHA-256, as unpadded base64url, must
/// start with the pin the engine reports. The bridge only exposes `fp16` (the
/// first 16 characters), so that prefix is what Flutter compares.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Unpadded base64url SHA-256 of the certificate's SubjectPublicKeyInfo, or
/// null when [der] is not a parsable X.509 certificate.
String? spkiFingerprint(Uint8List der) {
  final spki = _spkiOf(der);
  if (spki == null) return null;
  return base64Url.encode(sha256.convert(spki).bytes).replaceAll('=', '');
}

/// Whether the certificate matches [pinPrefix] (the stored pin or its first
/// characters). An empty or short pin never matches.
bool matchesPin(Uint8List der, String? pinPrefix) {
  if (pinPrefix == null || pinPrefix.length < 16) return false;
  final fp = spkiFingerprint(der);
  return fp != null && fp.startsWith(pinPrefix);
}

class _Tlv {
  const _Tlv(this.tag, this.start, this.contentStart, this.end);
  final int tag;
  final int start;
  final int contentStart;
  final int end;
}

_Tlv? _read(Uint8List b, int at, int limit) {
  if (at + 2 > limit) return null;
  final tag = b[at];
  var len = b[at + 1];
  var p = at + 2;
  if (len & 0x80 != 0) {
    final n = len & 0x7f;
    if (n == 0 || n > 4 || p + n > limit) return null;
    len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | b[p + i];
    }
    p += n;
  }
  if (p + len > limit) return null;
  return _Tlv(tag, at, p, p + len);
}

/// Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version OPTIONAL,
/// serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo,
/// ... }, ... }
Uint8List? _spkiOf(Uint8List der) {
  final cert = _read(der, 0, der.length);
  if (cert == null || cert.tag != 0x30) return null;
  final tbs = _read(der, cert.contentStart, cert.end);
  if (tbs == null || tbs.tag != 0x30) return null;
  var p = tbs.contentStart;
  var first = _read(der, p, tbs.end);
  if (first == null) return null;
  if (first.tag == 0xa0) p = first.end; // explicit version
  // serialNumber, signature, issuer, validity, subject
  for (var i = 0; i < 5; i++) {
    final e = _read(der, p, tbs.end);
    if (e == null) return null;
    p = e.end;
  }
  final spki = _read(der, p, tbs.end);
  if (spki == null || spki.tag != 0x30) return null;
  return Uint8List.sublistView(der, spki.start, spki.end);
}
