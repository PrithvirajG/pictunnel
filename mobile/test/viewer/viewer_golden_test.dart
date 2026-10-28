import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/features/timeline/timeline_model.dart';

import '../support/timeline_harness.dart';
import '../support/viewer_harness.dart';

/// Darkroom "A - Photo viewer": top bar with the date, a 390px photo area,
/// the green status row, the info list and the four-button action bar.
void main() {
  setUpTinyPng();
  setUpViewerPhoto();

  testWidgets('viewer golden', (t) async {
    await pumpViewer(t, [viewerItem('a', presence: Presence.both)]);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/viewer.png'),
    );
  });
}
