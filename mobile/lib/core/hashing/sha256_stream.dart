import 'dart:async';

import 'package:crypto/crypto.dart';

/// Streaming SHA-256 returning the lowercase hex digest. Never buffers the
/// whole input.
Future<String> sha256Hex(Stream<List<int>> bytes) async =>
    (await sha256.bind(bytes).first).toString();
