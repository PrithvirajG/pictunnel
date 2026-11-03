import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/app/app.dart';
import 'package:pictunnel/app/router.dart';
import 'package:pictunnel/features/timeline/timeline_providers.dart';
import 'package:pictunnel/app/theme/tokens.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/core/engine/fake_engine.dart';

Future<ProviderContainer> pump(
  WidgetTester t, {
  required bool connected,
}) async {
  final container = ProviderContainer(
    overrides: [
      serverConnectedProvider.overrideWith((_) async => connected),
      timelineMonthsProvider.overrideWithValue(const AsyncData(<MonthSummary>[])),
    ],
  );
  addTearDown(container.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const PicTunnelApp(),
    ),
  );
  await t.pumpAndSettle();
  return container;
}

Color? labelColor(WidgetTester t, String label) => t
    .widget<Text>(
      find.descendant(of: find.byType(InkWell), matching: find.text(label)),
    )
    .style
    ?.color;

String loc(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

void main() {
  testWidgets('shows three tabs and tapping switches route', (t) async {
    final c = await pump(t, connected: true);
    expect(find.text('Photos'), findsWidgets);
    expect(find.text('Backup'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(loc(c), '/photos');

    await t.tap(find.text('Backup'));
    await t.pumpAndSettle();
    expect(loc(c), '/backup');

    await t.tap(find.text('Settings'));
    await t.pumpAndSettle();
    expect(loc(c), '/settings');

    await t.tap(
      find.descendant(of: find.byType(InkWell), matching: find.text('Photos')),
    );
    await t.pumpAndSettle();
    expect(loc(c), '/photos');
  });

  testWidgets('active tab uses accent, inactive uses muted', (t) async {
    await pump(t, connected: true);
    expect(labelColor(t, 'Backup'), Tokens.muted);
    await t.tap(find.text('Backup'));
    await t.pumpAndSettle();
    expect(labelColor(t, 'Backup'), Tokens.accent);
    expect(labelColor(t, 'Settings'), Tokens.muted);
  });

  testWidgets('Backup tab shows the queued count', (t) async {
    final engine = FakeEngine()
      ..status = BackupStatus(
        backedUp: 0,
        total: 8,
        queued: 8,
        needsAttention: 0,
        skipped: 0,
        freeableBytes: 0,
        paused: false,
        preparing: 0,
        mediaAccess: MediaAccess.full,
      );
    final container = ProviderContainer(
      overrides: [
        serverConnectedProvider.overrideWith((_) async => true),
        timelineMonthsProvider.overrideWithValue(const AsyncData(<MonthSummary>[])),
        engineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const PicTunnelApp(),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Backup · 8'), findsOneWidget);
    expect(find.text('Backup'), findsNothing);
  });

  testWidgets('redirects to /pair when no server is connected', (t) async {
    final c = await pump(t, connected: false);
    expect(loc(c), '/pair');
    expect(find.text('Backup'), findsNothing);
  });
}
