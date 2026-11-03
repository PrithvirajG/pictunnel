import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/composition.dart';
import 'features/settings/about_screen.dart';
import 'features/viewer/viewer_actions.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  final env = await loadEnvironment();
  // Share folders an interrupted share left behind.
  unawaited(
    getTemporaryDirectory().then(sweepShareFolders).catchError((Object _) {}),
  );
  runApp(
    ProviderScope(overrides: appOverrides(env), child: const PicTunnelApp()),
  );
}
