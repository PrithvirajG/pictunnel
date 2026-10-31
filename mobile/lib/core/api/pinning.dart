/// Certificate pinning for the Flutter browse client and the playback proxy
/// (P§6.3).
///
/// A chain the system trusts never reaches this code (dart:io accepts it).
/// For anything else, the leaf's SPKI SHA-256, as unpadded base64url, must
/// equal the full pin the engine stores (`ServerConnection.fpFull`), compared
/// in constant time. There is no fallback to the 16-character `fp16`: a short,
/// missing or different pin is rejected.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Unpadded base64url SHA-256 of the certificate's SubjectPublicKeyInfo, or
/// null when [der] is not a parsable X.509 certificate.
String? spkiFingerprint(Uint8List der) {
  final spki = _spkiOf(der);
  if (spki == null) return null;
  return base64Url.encode(sha256.convert(spki).bytes).replaceAll('=', '');
}

/// The length of an unpadded base64url SHA-256.
const fullPinLength = 43;

/// Whether the certificate's SPKI SHA-256 equals [pin], the full stored pin
/// (unpadded base64url; padding and standard base64 are normalized as the
/// engines do). Anything but a full-length pin is rejected.
bool matchesPin(Uint8List der, String? pin) {
  if (pin == null) return false;
  final want = normalizePin(pin);
  if (want.length != fullPinLength) return false;
  final fp = spkiFingerprint(der);
  return fp != null && constantTimeEquals(fp, want);
}

/// Trims, drops `=` padding and maps standard base64 to base64url.
String normalizePin(String pin) => pin
    .trim()
    .replaceAll(RegExp(r'=+$'), '')
    .replaceAll('+', '-')
    .replaceAll('/', '_');

/// Equality whose running time does not depend on where the strings differ.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}

/// An [HttpClient] that accepts what the system trusts, or a leaf matching
/// the pin [pin] returns at handshake time (the engine's current `fpFull`).
HttpClient pinnedHttpClient(String? Function() pin) =>
    HttpClient()
      ..badCertificateCallback = (cert, host, port) =>
          matchesPin(cert.der, pin());

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
