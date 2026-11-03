import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/app/theme/theme.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/features/pairing/pairing_controller.dart';
import 'package:pictunnel/features/settings/about_screen.dart';
import 'package:pictunnel/features/settings/battery_hint.dart';
import 'package:pictunnel/features/settings/settings_screen.dart';

import 'settings_screen_test.dart' show settingsEngine;

class _Battery implements BatteryOptimization {
  _Battery({required this.exempt});
  bool exempt;
  var requests = 0;

  @override
  Future<bool> isExempt() async => exempt;

  @override
  Future<void> requestExemption() async {
    requests++;
    exempt = true;
  }
}

Future<void> _pump(WidgetTester t, BatteryOptimization b, HintStore s) async {
  t.view.physicalSize = const Size(390 * 2, 844 * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        engineProvider.overrideWithValue(settingsEngine()),
        deviceNameProvider.overrideWithValue('Pixel 9'),
        serverVersionProvider.overrideWith((_) async => '0.9.1'),
        batteryOptimizationProvider.overrideWithValue(b),
        hintStoreProvider.overrideWithValue(s),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: darkroomTheme(),
        home: const Scaffold(body: SettingsScreen()),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('not exempt: the card shows and Allow opens the system flow', (
    t,
  ) async {
    final b = _Battery(exempt: false);
    await _pump(t, b, MemoryHintStore());
    expect(find.byKey(const Key('batteryHint')), findsOneWidget);
    expect(find.text(batteryHintCopy), findsOneWidget);

    await t.tap(find.byKey(const Key('batteryHintAllow')));
    await t.pumpAndSettle();
    expect(b.requests, 1);
    expect(find.byKey(const Key('batteryHint')), findsNothing);
  });

  testWidgets('Not now hides it for good', (t) async {
    final store = MemoryHintStore();
    await _pump(t, _Battery(exempt: false), store);
    await t.tap(find.byKey(const Key('batteryHintDismiss')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('batteryHint')), findsNothing);
    expect(await store.isDismissed(batteryHint), isTrue);
  });

  testWidgets('exempt: no card', (t) async {
    await _pump(t, _Battery(exempt: true), MemoryHintStore());
    expect(find.byKey(const Key('batteryHint')), findsNothing);
  });

  group('channel', () {
    const channel = MethodChannel('pictunnel/battery');
    final calls = <String>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return call.method == 'isIgnoringBatteryOptimizations'
                ? false
                : true;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('Android asks the platform', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const b = ChannelBatteryOptimization();
      expect(await b.isExempt(), isFalse);
      await b.requestExemption();
      expect(calls, [
        'isIgnoringBatteryOptimizations',
        'requestIgnoreBatteryOptimizations',
      ]);
    });

    test('iOS is always exempt and never calls the channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await const ChannelBatteryOptimization().isExempt(), isTrue);
      expect(calls, isEmpty);
    });
  });
}
