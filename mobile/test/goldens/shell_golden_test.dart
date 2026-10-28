import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/app/app.dart';
import 'package:pictunnel/app/router.dart';
import 'package:pictunnel/features/timeline/timeline_model.dart';
import 'package:pictunnel/features/timeline/timeline_providers.dart';

void main() {
  testWidgets('shell golden', (t) async {
    t.view.physicalSize = const Size(390 * 2, 844 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
      serverConnectedProvider.overrideWith((_) async => true),
      timelineMonthsProvider.overrideWith((_) => Stream.value(<MonthKey>[])),
    ],
        child: const PicTunnelApp(),
      ),
    );
    await t.pumpAndSettle();
    await expectLater(
      find.byType(PicTunnelApp),
      matchesGoldenFile('shell.png'),
    );
  });
}
