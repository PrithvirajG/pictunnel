import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme/theme.dart';

class PicTunnelApp extends ConsumerWidget {
  const PicTunnelApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'PicTunnel',
      theme: darkroomTheme(),
      darkTheme: darkroomTheme(),
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
