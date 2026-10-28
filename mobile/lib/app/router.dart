import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/engine/engine.dart';
import '../features/activity/activity_screen.dart';
import '../features/attention/attention_screen.dart';
import '../features/backup/backup_screen.dart';
import '../features/pairing/manual_server_screen.dart';
import '../features/pairing/pair_screen.dart';
import '../features/timeline/timeline_screen.dart';
import '../features/trash/trash_screen.dart';
import '../features/viewer/viewer_screen.dart';
import 'shell.dart';
import 'theme/tokens.dart';
import 'theme/typography.dart';

/// Whether the engine has a paired server (`engine.serverInfo() != null`).
/// Re-evaluates when the engine reports `needsRepair` (credentials wiped) and
/// is invalidated after a successful pairing.
final serverConnectedProvider = FutureProvider<bool>((ref) async {
  final engine = ref.watch(engineProvider);
  final sub = engine.needsRepair$.listen((_) => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return await engine.serverInfo() != null;
});

final routerProvider = Provider<GoRouter>((ref) {
  final router = buildRouter(ref);
  ref.onDispose(router.dispose);
  return router;
});

GoRouter buildRouter(Ref ref) {
  // Root navigator, so the viewer covers the shell's bottom navigation.
  final rootNavigatorKey = GlobalKey<NavigatorState>();
  final refresh = ValueNotifier<int>(0);
  ref.listen(serverConnectedProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/photos',
    refreshListenable: refresh,
    redirect: (context, state) {
      final connected = ref.read(serverConnectedProvider).value;
      if (connected == null) return null; // still resolving
      final atPair = state.matchedLocation.startsWith('/pair');
      if (!connected && !atPair) return '/pair';
      if (connected && atPair) return '/photos';
      return null;
    },
    routes: [
      GoRoute(
        path: '/pair',
        builder: (_, _) => const PairScreen(),
        routes: [
          GoRoute(
            path: 'manual',
            builder: (_, _) => const ManualServerScreen(),
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/photos',
                builder: (_, _) => const TimelineScreen(),
                routes: [
                  GoRoute(
                    path: ':assetKey',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (_, s) =>
                        ViewerScreen(assetKey: s.pathParameters['assetKey']!),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/backup',
                builder: (_, _) => const BackupScreen(),
                routes: [
                  GoRoute(
                    path: 'attention',
                    builder: (_, _) => const AttentionScreen(),
                  ),
                  GoRoute(
                    path: 'activity',
                    builder: (_, _) => const ActivityScreen(),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, _) => const PlaceholderScreen('Settings'),
                routes: [
                  GoRoute(
                    path: 'trash',
                    builder: (_, _) => const TrashScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

/// Temporary screen body until the feature tasks replace each route.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(title, style: displayStyle(color: Tokens.text)),
        ),
      ),
    );
  }
}
