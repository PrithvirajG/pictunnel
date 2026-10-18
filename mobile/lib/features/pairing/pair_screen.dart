import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import 'pair_widgets.dart';
import 'pairing_controller.dart';
import 'qr_scanner_view.dart';

class PairScreen extends ConsumerWidget {
  const PairScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(qrPairingProvider);
    final c = ref.read(qrPairingProvider.notifier);
    final scanning = s.phase == QrPhase.scanning;
    final failed = s.phase == QrPhase.failed;
    final uri = s.uri;

    return Scaffold(
      backgroundColor: Tokens.ground,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pair with your server',
                  style: displayStyle(size: 30, color: Tokens.text)),
              const SizedBox(height: 10),
              Text(
                'On your computer, open PicTunnel and choose Add phone. '
                'Point the camera at the code it shows.',
                style: bodyStyle(size: 15, color: softText),
              ),
              const SizedBox(height: 22),
              ScannerPanel(
                child: ref
                    .watch(qrScannerProvider)
                    .build(context, c.onScanned),
              ),
              const SizedBox(height: 16),
              if (scanning && s.failure != null) FailureNotice(s.failure!),
              if (uri != null) ...[
                ServerCard(
                  title: 'Server found',
                  name: Uri.parse(uri.endpoints.first).host,
                  url: uri.endpoints.first,
                  fp16: uri.fingerprint,
                  onLan: isLanUrl(uri.endpoints.first),
                  helper: "Matches the code on your server's screen.",
                ),
                const SizedBox(height: 16),
                if (failed) ...[
                  FailureNotice(s.failure!),
                  const SizedBox(height: 12),
                ],
                if (failed && s.failure!.canPairAgain)
                  PrimaryButton(label: 'Pair again', onPressed: c.reset)
                else
                  PrimaryButton(
                    label: 'Connect and start backup',
                    busy: s.phase == QrPhase.connecting,
                    onPressed: c.connect,
                  ),
              ],
              const SizedBox(height: 8),
              AmberLink(
                'Enter a server address instead',
                onTap: () => context.push('/pair/manual'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
