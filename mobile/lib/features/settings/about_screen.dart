import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../app/version.dart';
import 'settings_screen.dart';

/// The paired server's version (`GET /server/info`); null when unknown.
/// The composition root overrides it with the real call.
final serverVersionProvider = FutureProvider.autoDispose<String?>(
  (_) async => null,
);

/// The bundled fonts and their OFL texts (spec M§7.2: no runtime fetching).
const bundledFontLicenses = <(String, String)>[
  ('Bricolage Grotesque', 'assets/fonts/OFL-BricolageGrotesque.txt'),
  ('Figtree', 'assets/fonts/OFL-Figtree.txt'),
];

bool _fontLicensesRegistered = false;

/// Adds the bundled fonts' licenses to the [LicenseRegistry] (shown on the
/// licenses page). Safe to call more than once.
void registerFontLicenses() {
  if (_fontLicensesRegistered) return;
  _fontLicensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    for (final (family, asset) in bundledFontLicenses) {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await rootBundle.loadString(asset));
    }
  });
}

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(serverVersionProvider);
    return Scaffold(
      appBar: AppBar(title: Text('About', style: displayStyle(size: 20))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          SettingsCard(
            children: [
              const SettingsValueRow(label: 'PicTunnel', value: appVersion),
              SettingsValueRow(
                key: const Key('serverVersion'),
                label: 'Server',
                value: server.isLoading ? '…' : (server.value ?? 'Unknown'),
              ),
              SettingsNavRow(
                label: 'Licenses',
                hint: 'Open-source software and fonts',
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'PicTunnel',
                  applicationVersion: appVersion,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Bricolage Grotesque and Figtree are bundled with the app under '
              'the SIL Open Font License 1.1.',
              style: bodyStyle(size: 13, color: Tokens.muted),
            ),
          ),
        ],
      ),
    );
  }
}
