import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/timeline_harness.dart';

/// Darkroom "A - Photos timeline": header with two round buttons, "This week"
/// and month sections, 3 columns with 2px gaps, presence and video badges.
void main() {
  setUpTinyPng();

  testWidgets('timeline golden', (t) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/timeline.png'),
    );
  });

  testWidgets('timeline filtered golden', (t) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);
    await t.tap(find.byTooltip('Show only photos not on this phone'));
    await t.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/timeline_server_only.png'),
    );
  });

  testWidgets('timeline selecting golden', (t) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);
    await t.tap(find.byTooltip('Select'));
    await t.tap(tileOf('shaOnly1'));
    await t.tap(tileOf('shaBoth'));
    await t.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/timeline_selecting.png'),
    );
  });
}
