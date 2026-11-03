import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/core/engine/fake_engine.dart';
import 'package:pictunnel/features/backup/backup_providers.dart';

BackupStatus _status(int backedUp) => BackupStatus(
  backedUp: backedUp,
  total: 10,
  queued: 0,
  needsAttention: 0,
  skipped: 0,
  freeableBytes: 0,
  paused: false,
  preparing: 0,
  mediaAccess: MediaAccess.full,
);

/// Its seed call fails or answers late; `status$` can carry errors.
class _Engine extends FakeEngine {
  final seed = Completer<BackupStatus>();
  final events = StreamController<BackupStatus>.broadcast();

  @override
  Future<BackupStatus> getStatus() => seed.future;
  @override
  Stream<BackupStatus> get status$ => events.stream;
}

void main() {
  late _Engine engine;
  late ProviderContainer c;
  late ProviderSubscription<AsyncValue<BackupStatus>> sub;

  setUp(() {
    engine = _Engine();
    c = ProviderContainer(overrides: [engineProvider.overrideWithValue(engine)]);
    sub = c.listen(backupStatusProvider, (_, _) {});
  });
  tearDown(() {
    sub.close();
    c.dispose();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a failing seed is an error, and the events still follow', () async {
    engine.seed.completeError(PlatformException(code: 'not_paired'));
    await settle();
    expect(c.read(backupStatusProvider).hasError, isTrue);
    engine.events.add(_status(3));
    await settle();
    expect(c.read(backupStatusProvider).value?.backedUp, 3);
  });

  test('an error event does not end the stream', () async {
    engine.seed.complete(_status(1));
    await settle();
    engine.events.addError(PlatformException(code: 'internal'));
    await settle();
    expect(c.read(backupStatusProvider).hasError, isTrue);
    engine.events.add(_status(5));
    await settle();
    expect(c.read(backupStatusProvider).value?.backedUp, 5);
  });

  test('a late seed never replaces a live status', () async {
    engine.events.add(_status(7));
    await settle();
    engine.seed.complete(_status(1));
    await settle();
    expect(c.read(backupStatusProvider).value?.backedUp, 7);
  });
}
