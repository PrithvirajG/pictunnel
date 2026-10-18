import 'package:flutter/material.dart';
import 'package:pictunnel/features/pairing/qr_scanner_view.dart';

/// Camera-free [QrScanner]: tests call [scan] to simulate a detected code.
class FakeQrScanner implements QrScanner {
  void Function(String raw)? _onCode;

  void scan(String raw) => _onCode!(raw);

  @override
  Widget build(BuildContext context, void Function(String raw) onCode) {
    _onCode = onCode;
    return const ColoredBox(
      key: Key('fake-scanner'),
      color: Color(0xFF1A1A1A),
    );
  }
}
