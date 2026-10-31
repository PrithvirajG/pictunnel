import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sync/sync_driver.dart';
import 'router.dart';
import 'theme/theme.dart';

class PicTunnelApp extends ConsumerWidget {
  const PicTunnelApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(backgroundSyncProvider);
    return MaterialApp.router(
      title: 'PicTunnel',
      debugShowCheckedModeBanner: false,
      theme: darkroomTheme(),
      darkTheme: darkroomTheme(),
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
