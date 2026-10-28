import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/app/theme/theme.dart';
import 'package:pictunnel/features/trash/trash_screen.dart';

import '../support/timeline_harness.dart';
import '../support/viewer_harness.dart';

Future<ViewerRig> pumpTrash(WidgetTester t, {bool empty = false}) async {
  final rig = ViewerRig(
    const [],
    trashed: empty
        ? const []
        : [
            serverAsset('a', state: 'trashed'),
            serverAsset('b', state: 'trashed'),
          ],
  );
  t.view.physicalSize = const Size(390, 844) * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: rig.overrides,
      child: MaterialApp(theme: darkroomTheme(), home: const TrashScreen()),
    ),
  );
  await t.pumpAndSettle();
  return rig;
}

void main() {
  setUpTinyPng();
  setUpViewerPhoto();

  testWidgets('lists trashed assets', (t) async {
    await pumpTrash(t);
    expect(find.text('IMG_a.jpg'), findsOneWidget);
    expect(find.text('IMG_b.jpg'), findsOneWidget);
  });

  testWidgets('Restore calls the API and marks the row active', (t) async {
    final rig = await pumpTrash(t);
    await t.tap(find.text('Restore').first);
    await t.pumpAndSettle();
    expect(rig.api.restored, [
      ['a'],
    ]);
    expect(rig.dao.states, {'a': 'active'});
    expect(find.text('IMG_a.jpg'), findsNothing);
  });

  testWidgets('Delete forever confirms, then purges', (t) async {
    final rig = await pumpTrash(t);
    await t.tap(find.text('Delete forever').first);
    await t.pumpAndSettle();
    expect(rig.api.purged, isEmpty);
    await t.tap(find.widgetWithText(TextButton, 'Delete forever').last);
    await t.pumpAndSettle();
    expect(rig.api.purged, [
      ['a'],
    ]);
    expect(rig.dao.removed, ['a']);
  });

  testWidgets('Empty trash confirms, then empties', (t) async {
    final rig = await pumpTrash(t);
    await t.tap(find.byKey(const Key('emptyTrash')));
    await t.pumpAndSettle();
    expect(rig.api.emptied, 0);
    await t.tap(find.widgetWithText(TextButton, 'Empty trash').last);
    await t.pumpAndSettle();
    expect(rig.api.emptied, 1);
    expect(rig.dao.removedTrashed, 1);
    expect(find.text('Trash is empty'), findsOneWidget);
  });

  testWidgets('empty trash shows the empty state', (t) async {
    await pumpTrash(t, empty: true);
    expect(find.text('Trash is empty'), findsOneWidget);
  });
}
