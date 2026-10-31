import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mirror_sync.dart';

/// Keeps the server mirror fresh while the app runs (spec M§7.1): a sync at
/// start, on every return to the foreground, and every [interval] while in
/// the foreground. Failures are left for the next tick.
class MirrorSyncDriver {
  MirrorSyncDriver(
    this._sync, {
    this.interval = const Duration(seconds: 60),
    this.listenToLifecycle = true,
  });

  final MirrorSync _sync;
  final Duration interval;
  final bool listenToLifecycle;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _disposed = false;

  void start() {
    _schedule();
    unawaited(syncNow());
    if (listenToLifecycle) {
      _lifecycle = AppLifecycleListener(
        onResume: () {
          _schedule();
          unawaited(syncNow());
        },
        onHide: () => _timer?.cancel(),
      );
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed) return;
    _timer = Timer.periodic(interval, (_) => unawaited(syncNow()));
  }

  Future<void> syncNow() async {
    if (_disposed) return;
    try {
      await _sync.syncOnce();
    } catch (e) {
      debugPrint('mirror sync failed: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _lifecycle?.dispose();
  }
}

/// Watched by the app so background mirror sync runs while it is mounted.
/// Does nothing until the composition root overrides it.
final backgroundSyncProvider = Provider<void>((_) {});
