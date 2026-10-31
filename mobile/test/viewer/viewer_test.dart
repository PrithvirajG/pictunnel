import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/engine/pigeon.g.dart' show ItemState;
import 'package:pictunnel/features/timeline/timeline_model.dart';
import 'package:pictunnel/features/viewer/photo_page.dart';

import '../support/timeline_harness.dart';
import '../support/viewer_harness.dart';

bool enabled(WidgetTester t, String label) {
  final w = t.widget<InkWell>(find.byKey(Key('action$label')));
  return w.onTap != null;
}

void main() {
  setUpTinyPng();
  setUpViewerPhoto();

  group('actions per presence', () {
    testWidgets('both + BackedUp: Free up on, Original off, Trash on', (
      t,
    ) async {
      await pumpViewer(t, [viewerItem('a', presence: Presence.both)]);
      expect(enabled(t, 'Share'), isTrue);
      expect(enabled(t, 'Original'), isFalse);
      expect(enabled(t, 'Free up'), isTrue);
      expect(enabled(t, 'Trash'), isTrue);
    });

    testWidgets('both but not BackedUp: Free up off', (t) async {
      await pumpViewer(t, [
        viewerItem(
          'a',
          presence: Presence.both,
          phoneState: ItemState.uploading,
        ),
      ]);
      expect(enabled(t, 'Free up'), isFalse);
    });

    testWidgets('serverOnly: Original on, Free up off', (t) async {
      await pumpViewer(t, [viewerItem('a', presence: Presence.serverOnly)]);
      expect(enabled(t, 'Original'), isTrue);
      expect(enabled(t, 'Free up'), isFalse);
      expect(enabled(t, 'Trash'), isTrue);
    });

    testWidgets('phoneOnly: nothing server-side is enabled', (t) async {
      await pumpViewer(t, [
        viewerItem(
          'a',
          presence: Presence.phoneOnly,
          phoneState: ItemState.queued,
        ),
      ]);
      expect(enabled(t, 'Share'), isFalse);
      expect(enabled(t, 'Original'), isFalse);
      expect(enabled(t, 'Free up'), isFalse);
      expect(enabled(t, 'Trash'), isFalse);
    });
  });

  testWidgets('Original saves to the gallery via the engine', (t) async {
    final rig = await pumpViewer(t, [
      viewerItem('a', presence: Presence.serverOnly),
    ]);
    await t.tap(find.byKey(const Key('actionOriginal')));
    await t.pumpAndSettle();
    expect(rig.host.saved, [('a', 'IMG_a.jpg', 'image/jpeg')]);
    expect(find.text('Saved to your gallery'), findsOneWidget);
  });

  testWidgets('Free up frees the phone copy', (t) async {
    final rig = await pumpViewer(t, [viewerItem('a', presence: Presence.both)]);
    await t.tap(find.byKey(const Key('actionFree up')));
    await t.pumpAndSettle();
    expect(rig.host.freed, [
      ['local-a'],
    ]);
  });

  testWidgets('Share hands the server original to the share sheet', (t) async {
    final rig = await pumpViewer(t, [viewerItem('a', presence: Presence.both)]);
    await t.tap(find.byKey(const Key('actionShare')));
    await t.pumpAndSettle();
    expect(rig.share.shared, ['a']);
  });

  group('Trash', () {
    testWidgets('confirms, then calls the API and the local mirror', (t) async {
      final rig = await pumpViewer(t, [
        viewerItem('a', presence: Presence.both),
      ]);
      await t.tap(find.byKey(const Key('actionTrash')));
      await t.pumpAndSettle();
      expect(
        find.text('Removes it from your server. It stays on this phone.'),
        findsOneWidget,
      );
      expect(rig.api.trashed, isEmpty);

      await t.tap(find.text('Move to trash'));
      await t.pumpAndSettle();
      expect(rig.api.trashed, [
        ['a'],
      ]);
      expect(rig.dao.states, {'a': 'trashed'});
    });

    testWidgets('server-only copy names the 30 day Trash', (t) async {
      await pumpViewer(t, [viewerItem('a', presence: Presence.serverOnly)]);
      await t.tap(find.byKey(const Key('actionTrash')));
      await t.pumpAndSettle();
      expect(
        find.text("Moves it to your server's Trash for 30 days."),
        findsOneWidget,
      );
    });

    testWidgets('cancel does not call the API', (t) async {
      final rig = await pumpViewer(t, [
        viewerItem('a', presence: Presence.both),
      ]);
      await t.tap(find.byKey(const Key('actionTrash')));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(rig.api.trashed, isEmpty);
    });
  });

  testWidgets('video streams the playback URL with an auth header', (t) async {
    final rig = await pumpViewer(t, [
      viewerItem('v', presence: Presence.serverOnly, video: true),
    ]);
    expect(rig.video.sources, hasLength(1));
    final src = rig.video.sources.single;
    expect(src.uri, 'https://pt.test/api/v1/assets/v/playback');
    expect(src.httpHeaders, {'Authorization': 'Bearer pt_at_test'});
    expect(rig.playback.opened, ['v']);

    // Leaving the viewer closes the playback session (the app's proxy).
    await t.pumpWidget(const SizedBox());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
    expect(rig.video.disposed, isNotEmpty);
    expect(rig.playback.closed, 1);
  });

  testWidgets('Live Photo plays its video only while pressed', (t) async {
    final rig = await pumpViewer(t, [
      viewerItem('l', presence: Presence.serverOnly, live: true),
    ]);
    expect(find.text('LIVE'), findsOneWidget);
    expect(rig.video.sources, isEmpty);

    final g = await t.startGesture(
      t.getCenter(find.byKey(const Key('livePhoto'))),
    );
    await t.pump(const Duration(milliseconds: 700));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(rig.video.sources, hasLength(1));
    expect(
      rig.video.sources.single.httpHeaders['Authorization'],
      'Bearer pt_at_test',
    );
    await t.pump(const Duration(milliseconds: 50));
    expect(rig.video.played, isNotEmpty);

    await g.up();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pump(const Duration(milliseconds: 50));
    await t.pump(const Duration(milliseconds: 50));
    expect(rig.video.disposed, isNotEmpty);
  });

  testWidgets('zoom swaps the preview for the original', (t) async {
    final rig = await pumpViewer(t, [
      viewerItem('a', presence: Presence.serverOnly),
    ]);
    expect(find.byKey(const Key('photoView')), findsOneWidget);
    expect(rig.api.originals, isEmpty);

    final c = t.getCenter(find.byKey(const Key('photoView')));
    await t.tapAt(c);
    await t.pump(kDoubleTapMinTime);
    await t.tapAt(c);
    await t.pump(const Duration(milliseconds: 50));
    await settleImages(t);
    expect(rig.api.originals, ['a']);
  });

  testWidgets('info panel and status row', (t) async {
    await pumpViewer(t, [viewerItem('a', presence: Presence.both)]);
    expect(find.text('Mon 12 Oct · 18:42'), findsOneWidget);
    expect(
      find.text('Backed up to Home server · also on this phone'),
      findsOneWidget,
    );
    expect(find.text('IMG_a.jpg'), findsOneWidget);
    expect(find.text('4032 × 3024 · 3.2 MB'), findsOneWidget);
    expect(find.text('38.72° N, 9.14° W'), findsOneWidget);
    expect(find.text('alice / 2026 / 10'), findsOneWidget);
  });

  test('preview size name is the server derivative', () {
    expect(serverPreviewSize, 'preview');
  });
}
