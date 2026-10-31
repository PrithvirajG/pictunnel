import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/composition.dart';
import 'features/settings/about_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  final env = await loadEnvironment();
  runApp(
    ProviderScope(overrides: appOverrides(env), child: const PicTunnelApp()),
  );
}
