import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/core/engine/fake_engine.dart';
import 'package:pictunnel/core/thumbs/thumb_image.dart';
import 'package:pictunnel/features/timeline/tile.dart';

import '../support/timeline_harness.dart';

void main() {
  setUpTinyPng();

  testWidgets('badges per presence and state', (t) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);

    Finder badge(String tile, String name) => find.descendant(
      of: tileOf(tile),
      matching: find.byKey(Key('badge-$name')),
    );
    expect(badge('local:up', 'uploading'), findsOneWidget);
    expect(badge('local:q', 'uploading'), findsOneWidget);
    expect(badge('local:bad', 'attention'), findsOneWidget);
    expect(badge('shaOnly1', 'serverOnly'), findsOneWidget);
    // Both, backed up: no badge at all.
    for (final n in ['uploading', 'attention', 'serverOnly']) {
      expect(badge('shaBoth', n), findsNothing);
    }
    expect(
      find.descendant(of: tileOf('local:vid'), matching: find.text('0:14')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tileOf('local:live'), matching: find.text('LIVE')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tileOf('shaOnlyVid'), matching: find.text('1:15')),
      findsOneWidget,
    );
  });

  testWidgets('sections: This week folded first, month headers, captions', (
    t,
  ) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('10 Oct'), findsOneWidget);
    expect(find.text('September 2026'), findsOneWidget);
    expect(find.text('August 2026'), findsOneWidget);
    expect(
      t.getTopLeft(find.text('This week')).dy,
      lessThan(t.getTopLeft(find.text('September 2026')).dy),
    );
  });

  testWidgets('Not on this phone filter keeps only server-only items', (
    t,
  ) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);
    expect(tileOf('local:up'), findsOneWidget);

    await t.tap(find.byTooltip('Show only photos not on this phone'));
    await t.pumpAndSettle();
    expect(tileOf('local:up'), findsNothing);
    expect(tileOf('shaBoth'), findsNothing);
    expect(tileOf('shaOnly1'), findsOneWidget);
    expect(tileOf('shaOnly2'), findsOneWidget);
    expect(find.text('This week'), findsNothing);
    expect(find.text('On server only · 2'), findsOneWidget); // September
    expect(find.text('On server only · 1'), findsOneWidget); // August

    await t.tap(find.byTooltip('Show only photos not on this phone'));
    await t.pumpAndSettle();
    expect(tileOf('local:up'), findsOneWidget);
  });

  testWidgets('filter with nothing to show says so', (t) async {
    final e = FakeEngine()..phoneItems = [phone('a', DateTime(2026, 10, 10))];
    await pumpTimeline(t, engine: e);
    await t.tap(find.byTooltip('Show only photos not on this phone'));
    await t.pumpAndSettle();
    expect(
      find.text('Everything on your server is on this phone.'),
      findsOneWidget,
    );
  });

  testWidgets('multi-select: eligibility, count and actions', (t) async {
    final m = mixed();
    final actions = RecordingActions();
    await pumpTimeline(t, engine: m.engine, assets: m.assets, actions: actions);
    expect(find.byKey(const Key('selectionBar')), findsNothing);

    await t.tap(find.byTooltip('Select'));
    await t.pumpAndSettle();
    expect(find.text('Select items'), findsOneWidget);

    await t.tap(tileOf('shaOnly1'));
    await t.tap(tileOf('shaBoth'));
    await t.tap(tileOf('local:up'));
    await t.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.byKey(const Key('checked')), findsNWidgets(3));

    // Tapping again deselects.
    await t.tap(tileOf('local:up'));
    await t.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await t.tap(find.bySemanticsLabel('Download'));
    await t.pumpAndSettle();
    expect(actions.calls['download'], ['shaOnly1']);
    expect(find.byKey(const Key('selectionBar')), findsNothing);

    // Free up: only both + backed up. Trash: everything with a server copy,
    // behind a confirmation.
    await t.tap(find.byTooltip('Select'));
    await t.pumpAndSettle();
    await t.tap(tileOf('shaOnly1'));
    await t.tap(tileOf('shaBoth'));
    await t.tap(tileOf('local:bad'));
    await t.pumpAndSettle();

    await t.tap(find.bySemanticsLabel('Free up space'));
    await t.pumpAndSettle();
    expect(actions.calls['freeUp'], ['shaBoth']);

    await t.tap(find.byTooltip('Select'));
    await t.pumpAndSettle();
    await t.tap(tileOf('shaOnly1'));
    await t.tap(tileOf('shaBoth'));
    await t.tap(tileOf('local:bad'));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel('Trash'));
    await t.pumpAndSettle();
    expect(
      find.textContaining('Removes 2 items from your server'),
      findsOneWidget,
    );
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(actions.calls.containsKey('trash'), isFalse);
    expect(find.byKey(const Key('selectionBar')), findsOneWidget);

    await t.tap(find.bySemanticsLabel('Trash'));
    await t.pumpAndSettle();
    await t.tap(find.text('Move to trash'));
    await t.pumpAndSettle();
    expect(actions.calls['trash'], unorderedEquals(['shaOnly1', 'shaBoth']));
    expect(find.byKey(const Key('selectionBar')), findsNothing);
  });

  testWidgets('actions are disabled when nothing selected applies', (t) async {
    final m = mixed();
    final actions = RecordingActions();
    await pumpTimeline(t, engine: m.engine, assets: m.assets, actions: actions);
    await t.tap(find.byTooltip('Select'));
    await t.pumpAndSettle();
    await t.tap(tileOf('local:bad'));
    await t.pumpAndSettle();
    await t.tap(find.text('Download'), warnIfMissed: false);
    await t.tap(find.text('Trash'), warnIfMissed: false);
    await t.tap(find.text('Free up space'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(actions.calls, isEmpty);
    expect(find.text('Move to trash'), findsNothing);
  });

  testWidgets('long press starts selecting; close ends it', (t) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);
    await t.longPress(tileOf('shaOnly2'));
    await t.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Cancel selection'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('selectionBar')), findsNothing);
    expect(find.byKey(const Key('unchecked')), findsNothing);
  });

  testWidgets('tap opens the viewer route for the item key', (t) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);
    await t.tap(tileOf('local:q'));
    await t.pumpAndSettle();
    expect(find.text('detail local:q'), findsOneWidget);
  });

  testWidgets('pinch switches between 3 and 5 columns', (t) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);
    double tileWidth() => t.getSize(tileOf('local:up')).width;
    expect(tileWidth(), closeTo((390 - 4) / 3, 0.01));
    expect(t.getSize(tileOf('local:up')).height, tileWidth());

    Future<void> pinch(double from, double to) async {
      final a = await t.startGesture(Offset(195 - from / 2, 400));
      final b = await t.startGesture(Offset(195 + from / 2, 400));
      for (var i = 1; i <= 5; i++) {
        final d = from + (to - from) * i / 5;
        await a.moveTo(Offset(195 - d / 2, 400));
        await b.moveTo(Offset(195 + d / 2, 400));
        await t.pump();
      }
      await a.up();
      await b.up();
      await t.pumpAndSettle();
    }

    await pinch(200, 80); // fingers together: smaller tiles, 5 columns
    expect(tileWidth(), closeTo((390 - 8) / 5, 0.01));
    final firstRow = t.getTopLeft(tileOf('local:up')).dy;
    expect(t.getTopLeft(tileOf('local:q')).dy, firstRow);
    expect(t.getTopLeft(tileOf('local:bad')).dy, firstRow);
    expect(t.getTopLeft(tileOf('shaBoth')).dy, firstRow);
    expect(t.getTopLeft(tileOf('local:vid')).dy, firstRow);

    await pinch(80, 220); // fingers apart: back to 3
    expect(tileWidth(), closeTo((390 - 4) / 3, 0.01));
  });

  testWidgets('a single finger drag scrolls and never changes columns', (
    t,
  ) async {
    final m = mixed();
    await pumpTimeline(t, engine: m.engine, assets: m.assets);
    await t.drag(find.byKey(const Key('timelineList')), const Offset(0, -200));
    await t.pumpAndSettle();
    expect(t.getSize(tileOf('local:up')).width, closeTo((390 - 4) / 3, 0.01));
  });

  testWidgets('phone item change re-merges its month', (t) async {
    final e = FakeEngine()
      ..phoneItems = [
        phone('x', DateTime(2026, 10, 10), state: ItemState.queued),
      ];
    await pumpTimeline(t, engine: e);
    expect(find.byKey(const Key('badge-uploading')), findsOneWidget);

    e.phoneItems = [
      phone('x', DateTime(2026, 10, 10), state: ItemState.backedUp),
    ];
    e.emitItem(e.phoneItems.single);
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('badge-uploading')), findsNothing);
  });

  testWidgets('10k items: only visible rows build, scrolling stays bounded', (
    t,
  ) async {
    final e = CountingEngine();
    e.phoneItems = [
      for (var i = 0; i < 10000; i++)
        phone('p$i', DateTime(2026, 10, 10).subtract(Duration(hours: i))),
    ];
    final sw = Stopwatch()..start();
    await pumpTimeline(t, engine: e);
    final built = find.byType(TimelineTile).evaluate().length;
    expect(built, inInclusiveRange(1, 80));
    expect(e.thumbCalls, lessThanOrEqualTo(built * 2));

    final list = find.byKey(const Key('timelineList'));
    var peak = built;
    for (var i = 0; i < 20; i++) {
      await t.fling(list, const Offset(0, -1200), 4000);
      await t.pump(const Duration(milliseconds: 100));
      final n = find.byType(TimelineTile).evaluate().length;
      if (n > peak) peak = n;
    }
    await t.pumpAndSettle();
    expect(peak, lessThanOrEqualTo(80));
    // 20 flings of ~1200px at 3 columns touch far fewer than 10k tiles.
    expect(e.thumbCalls, lessThan(2000));
    expect(sw.elapsed, lessThan(const Duration(seconds: 60)));
  });

  group('ThumbImage', () {
    testWidgets('phone and both items use the phone thumbnail, not the cache', (
      t,
    ) async {
      final cache = FakeThumbCache(tinyPng);
      final e = CountingEngine();
      e.phoneItems = [
        phone('a', DateTime(2026, 10, 10), sha: 'shaBoth'),
        phone('b', DateTime(2026, 10, 9)),
      ];
      await pumpTimeline(
        t,
        engine: e,
        cache: cache,
        assets: [server('sBoth', 'shaBoth', DateTime(2026, 10, 10))],
      );
      expect(e.thumbCalls, 2);
      expect(cache.requests, isEmpty);
    });

    testWidgets('server-only items fetch the cached server thumb', (t) async {
      final cache = FakeThumbCache(tinyPng);
      await pumpTimeline(
        t,
        engine: FakeEngine(),
        cache: cache,
        assets: [server('sOnly', 'shaOnly', DateTime(2026, 10, 10))],
      );
      expect(cache.requests, ['sOnly/thumb']);
      expect(
        find.descendant(of: tileOf('shaOnly'), matching: find.byType(Image)),
        findsOneWidget,
      );
    });

    testWidgets('not ready: tonal placeholder, retried later', (t) async {
      final cache = FakeThumbCache(null);
      final container = await pumpTimeline(
        t,
        engine: FakeEngine(),
        cache: cache,
        assets: [server('sOnly', 'shaOnly', DateTime(2026, 10, 10))],
      );
      expect(cache.requests.length, 1);
      expect(
        find.descendant(
          of: tileOf('shaOnly'),
          matching: find.byKey(const Key('thumbPlaceholder')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tileOf('shaOnly'), matching: find.byType(Image)),
        findsNothing,
      );
      await t.pump(thumbRetryDelay + const Duration(seconds: 1));
      expect(cache.requests.length, 2);
      // Leave no retry timer behind.
      container.dispose();
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await t.pump(const Duration(seconds: 1));
    });
  });
}
