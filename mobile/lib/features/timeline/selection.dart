import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart' show ItemState;
import 'timeline_model.dart';

class SelectionState {
  const SelectionState({this.active = false, this.keys = const {}});

  final bool active;
  final Set<String> keys;
}

class SelectionController extends Notifier<SelectionState> {
  @override
  SelectionState build() => const SelectionState();

  /// Enters selection mode, optionally selecting [key].
  void enter([String? key]) =>
      state = SelectionState(active: true, keys: {...state.keys, ?key});

  void exit() => state = const SelectionState();

  void toggle(String key) {
    final keys = {...state.keys};
    if (!keys.remove(key)) keys.add(key);
    state = SelectionState(active: true, keys: keys);
  }
}

final selectionProvider = NotifierProvider<SelectionController, SelectionState>(
  SelectionController.new,
);

/// What the selection bar does with the selected items. Later tasks (viewer
/// actions, free-up flow) provide the real implementation.
abstract class TimelineActions {
  Future<void> download(List<TimelineItem> items);
  Future<void> trash(List<TimelineItem> items);
  Future<void> freeUp(List<TimelineItem> items);
}

class NoopTimelineActions implements TimelineActions {
  const NoopTimelineActions();
  @override
  Future<void> download(List<TimelineItem> items) async {}
  @override
  Future<void> trash(List<TimelineItem> items) async {}
  @override
  Future<void> freeUp(List<TimelineItem> items) async {}
}

final timelineActionsProvider = Provider<TimelineActions>(
  (_) => const NoopTimelineActions(),
);

/// Items a download applies to: on the server but not on this phone.
List<TimelineItem> downloadable(Iterable<TimelineItem> xs) => [
  for (final x in xs)
    if (x.presence == Presence.serverOnly) x,
];

/// Items with a server copy that can be trashed.
List<TimelineItem> trashable(Iterable<TimelineItem> xs) => [
  for (final x in xs)
    if (x.server != null) x,
];

/// Items whose phone copy may be freed: on both sides and backed up.
List<TimelineItem> freeable(Iterable<TimelineItem> xs) => [
  for (final x in xs)
    if (x.presence == Presence.both && x.phoneState == ItemState.backedUp) x,
];
