import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import 'pair_widgets.dart';
import 'pairing_controller.dart';

/// Manual setup: mDNS suggestions or a typed URL, then a fingerprint
/// comparison (trust on first use, P§6.3 step 5), then the pairing code.
class ManualServerScreen extends ConsumerStatefulWidget {
  const ManualServerScreen({super.key});

  @override
  ConsumerState<ManualServerScreen> createState() => _ManualServerScreenState();
}

class _ManualServerScreenState extends ConsumerState<ManualServerScreen> {
  final _url = TextEditingController();
  final _code = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _code.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, String? hint) => InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: Tokens.surface,
        labelStyle: bodyStyle(color: Tokens.muted),
        hintStyle: bodyStyle(color: Tokens.muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Tokens.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Tokens.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Tokens.accent),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(manualPairingProvider);
    final c = ref.read(manualPairingProvider.notifier);
    final id = s.identity;
    final verifying =
        id != null && (s.phase == ManualPhase.verify || s.phase == ManualPhase.connecting);

    return Scaffold(
      backgroundColor: Tokens.ground,
      appBar: AppBar(
        backgroundColor: Tokens.ground,
        foregroundColor: Tokens.text,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Enter a server address',
                  style: displayStyle(size: 30, color: Tokens.text)),
              const SizedBox(height: 10),
              Text(
                verifying
                    ? 'Compare the security code with the one on your '
                        "server's admin page, then enter the pairing code."
                    : 'Use the address shown on your computer, or pick a '
                        'server found on this network.',
                style: bodyStyle(size: 15, color: softText),
              ),
              const SizedBox(height: 20),
              if (!verifying) ..._entry(s, c) else ..._verify(s, c, id),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _entry(ManualPairingState s, ManualPairingController c) {
    final lookingUp = s.phase == ManualPhase.lookingUp;
    final suggestions = ref.watch(discoveredServersProvider).value ?? const [];
    return [
      if (suggestions.isNotEmpty) ...[
        Text('FOUND ON THIS NETWORK',
            style: bodyStyle(size: 12, weight: 600, color: Tokens.muted)
                .copyWith(letterSpacing: 1.0)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final u in suggestions)
              ActionChip(
                label: Text(u, style: bodyStyle(color: Tokens.text)),
                backgroundColor: Tokens.surface,
                side: const BorderSide(color: Tokens.line),
                onPressed: () => setState(() => _url.text = u),
              ),
          ],
        ),
        const SizedBox(height: 16),
      ],
      TextField(
        key: const Key('server-url'),
        controller: _url,
        keyboardType: TextInputType.url,
        autocorrect: false,
        style: bodyStyle(size: 16),
        decoration: _decoration('Server address', 'https://my-server.local:8443'),
        onSubmitted: c.lookUp,
      ),
      const SizedBox(height: 12),
      if (s.failure != null) ...[
        FailureNotice(s.failure!),
        const SizedBox(height: 12),
      ],
      PrimaryButton(
        label: 'Continue',
        busy: lookingUp,
        onPressed: () => c.lookUp(_url.text),
      ),
    ];
  }

  List<Widget> _verify(
      ManualPairingState s, ManualPairingController c, ServerIdentity id) {
    final f = s.failure;
    return [
      ServerCard(
        title: null,
        name: id.name,
        url: s.url ?? id.url,
        fp16: id.fp16,
        onLan: isLanUrl(s.url ?? id.url),
        helper: 'Both codes must match exactly. If they differ, do not continue.',
      ),
      const SizedBox(height: 16),
      TextField(
        key: const Key('pair-code'),
        controller: _code,
        autocorrect: false,
        textCapitalization: TextCapitalization.characters,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9A-Za-z-]'))],
        style: const TextStyle(
            fontFamily: 'monospace', fontSize: 18, color: Tokens.text),
        decoration: _decoration('Pairing code', 'XXXX-XXXX-XX'),
        onSubmitted: c.connect,
      ),
      const SizedBox(height: 12),
      if (f != null) ...[
        FailureNotice(f),
        const SizedBox(height: 12),
      ],
      if (f != null && f.canPairAgain)
        PrimaryButton(label: 'Pair again', onPressed: c.reset)
      else
        PrimaryButton(
          label: 'Connect and start backup',
          busy: s.phase == ManualPhase.connecting,
          onPressed: () => c.connect(_code.text),
        ),
    ];
  }
}
