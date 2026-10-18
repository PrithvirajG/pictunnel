import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/theme/tokens.dart';

/// Camera QR scanning behind a seam so widget tests need no camera.
abstract interface class QrScanner {
  /// A widget that calls [onCode] with the raw value of each detected QR code.
  Widget build(BuildContext context, void Function(String raw) onCode);
}

/// [QrScanner] backed by `mobile_scanner`.
class MobileQrScanner implements QrScanner {
  const MobileQrScanner();

  @override
  Widget build(BuildContext context, void Function(String raw) onCode) {
    return MobileScanner(
      onDetect: (capture) {
        for (final b in capture.barcodes) {
          final raw = b.rawValue;
          if (raw != null) {
            onCode(raw);
            return;
          }
        }
      },
      errorBuilder: (context, error) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Camera unavailable. Allow camera access in Settings, or enter a server address instead.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Tokens.muted),
          ),
        ),
      ),
    );
  }
}

final qrScannerProvider = Provider<QrScanner>((_) => const MobileQrScanner());

/// The 300 dp scanner panel: #1A1A1A, radius 20, amber 4 px corner brackets.
class ScannerPanel extends StatelessWidget {
  const ScannerPanel({super.key, required this.child});
  final Widget child;

  static const background = Color(0xFF1A1A1A);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 300,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: background),
            child,
            const Padding(
              padding: EdgeInsets.all(28),
              child: CustomPaint(painter: _BracketPainter()),
            ),
          ],
        ),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  const _BracketPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Tokens.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const len = 36.0;
    final w = size.width, h = size.height;
    canvas.drawPath(
      Path()
        ..moveTo(0, len)
        ..lineTo(0, 0)
        ..lineTo(len, 0)
        ..moveTo(w - len, 0)
        ..lineTo(w, 0)
        ..lineTo(w, len)
        ..moveTo(w, h - len)
        ..lineTo(w, h)
        ..lineTo(w - len, h)
        ..moveTo(len, h)
        ..lineTo(0, h)
        ..lineTo(0, h - len),
      p,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}
