import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import 'pairing_controller.dart';

const softText = Color(0xFFC9C4BB);
const onAccent = Color(0xFF1A1206);
const errorText = Color(0xFFF2A28B);

/// "Server found" / fingerprint card (#1C1C1C, radius 16).
class ServerCard extends StatelessWidget {
  const ServerCard({
    super.key,
    required this.title,
    required this.name,
    required this.url,
    required this.fp16,
    this.onLan = false,
    this.helper,
  });

  final String? title;
  final String name;
  final String url;
  final String fp16;
  final bool onLan;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Tokens.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Tokens.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(title!, style: bodyStyle(size: 13, color: Tokens.muted)),
            const SizedBox(height: 6),
          ],
          Text(name, style: bodyStyle(size: 17, weight: 600)),
          if (onLan) ...[
            const SizedBox(height: 2),
            Text('On this network',
                style: bodyStyle(size: 14, color: Tokens.ok)),
          ],
          const SizedBox(height: 2),
          Text(url, style: bodyStyle(size: 14, color: softText)),
          const SizedBox(height: 14),
          Text('SECURITY CODE',
              style: bodyStyle(size: 12, weight: 600, color: Tokens.muted)
                  .copyWith(letterSpacing: 1.0)),
          const SizedBox(height: 4),
          Text(
            groupFingerprint(fp16),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              color: Tokens.text,
              letterSpacing: 1.0,
            ),
          ),
          if (helper != null) ...[
            const SizedBox(height: 6),
            Text(helper!, style: bodyStyle(size: 13, color: Tokens.muted)),
          ],
        ],
      ),
    );
  }
}

/// 52 dp pill button, amber with dark text.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: Material(
        color: onPressed == null ? Tokens.accent.withValues(alpha: 0.5) : Tokens.accent,
        borderRadius: BorderRadius.circular(26),
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: busy ? null : onPressed,
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: onAccent),
                    )
                  : Text(label,
                      style: bodyStyle(size: 16, weight: 600, color: onAccent)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Amber text link with a 48 dp touch target.
class AmberLink extends StatelessWidget {
  const AmberLink(this.label, {super.key, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: Center(
          child: Text(label,
              style: bodyStyle(size: 15, weight: 600, color: Tokens.accent)),
        ),
      ),
    );
  }
}

/// Failure banner; "Pair again" replaces the connect button on a pin mismatch.
class FailureNotice extends StatelessWidget {
  const FailureNotice(this.failure, {super.key});
  final PairFailure failure;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Text(failure.message,
          style: bodyStyle(size: 14, color: errorText)),
    );
  }
}
