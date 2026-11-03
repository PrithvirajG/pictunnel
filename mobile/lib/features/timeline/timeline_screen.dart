import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/error_copy.dart';
import 'month_section.dart';
import 'selection.dart';
import 'selection_bar.dart';
import 'tile.dart';
import 'timeline_layout.dart';
import 'timeline_model.dart';
import 'timeline_providers.dart';

/// Photos tab: the unified timeline (M§7.1) as one lazy fixed-extent list of
/// month headers and rows of square tiles. Every month has rows from its
/// counts; only the months near the viewport are loaded (the rest show
/// placeholder tiles), so a 100k library costs the same as a small one.
class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});

  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  static const _pinchIn = 0.8, _pinchOut = 1.25;

  int _columns = 3;
  bool _notOnPhoneOnly = false;
  final _pointers = <int, Offset>{};
  double? _baseline;
  final _scroll = ScrollController();
  late final TimelineWindow _window;

  /// What each month held when it was last loaded, per filter mode, so a
  /// month that scrolls away keeps its size instead of an estimate.
  final _known = <bool, Map<MonthKey, int>>{false: {}, true: {}};

  /// The last laid-out rows and the scroll offset where each one starts.
  List<TimelineRow> _rows = const [];
  List<double> _starts = const [];

  @override
  void initState() {
    super.initState();
    _window = ref.read(timelineWindowProvider.notifier);
    _scroll.addListener(_updateWindow);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Asks for the months of the rows on screen, plus half a screen above and
  /// two below; months outside it are released. Bounded work: a binary
  /// search, then only the rows in that band.
  void _updateWindow() {
    if (!_scroll.hasClients || _rows.isEmpty) return;
    final pos = _scroll.position;
    final top = pos.pixels - pos.viewportDimension * 0.5;
    final bottom = pos.pixels + pos.viewportDimension * 2;
    var lo = 0, hi = _starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (_starts[mid] <= top) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final months = <MonthKey>{};
    for (var i = lo; i < _rows.length && _starts[i] <= bottom; i++) {
      final m = _rows[i].month;
      if (m != null) months.add(m);
    }
    _window.request(timelineOwner, months);
  }

  double get _distance {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    _baseline = _pointers.length == 2 ? _distance : null;
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final base = _baseline;
    if (_pointers.length != 2 || base == null || base == 0) return;
    final ratio = _distance / base;
    if (ratio < _pinchIn && _columns == 3) {
      setState(() => _columns = 5);
      _baseline = _distance;
    } else if (ratio > _pinchOut && _columns == 5) {
      setState(() => _columns = 3);
      _baseline = _distance;
    }
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    _baseline = null;
  }

  /// Pull-to-refresh: mirror sync plus an engine run (M§7.1).
  Future<void> _refresh() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(timelineRefreshProvider)();
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(engineErrorMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(timelineSectionsProvider);
    final selection = ref.watch(selectionProvider);
    final value = data.value;
    final sections = value?.sections ?? const <TimelineSection>[];
    final loaded = value?.loaded ?? const <MonthKey>{};
    final known = _known[_notOnPhoneOnly]!;
    final display = buildDisplaySections(
      sections,
      notOnPhoneOnly: _notOnPhoneOnly,
      months: value?.months ?? const [],
      loaded: loaded,
      knownCounts: known,
    );
    // Remember loaded month sizes (a loaded month with nothing to show is 0).
    for (final m in loaded) {
      known[m] = 0;
    }
    for (final d in display) {
      final m = d.month;
      if (m != null && !d.isPlaceholder) known[m] = d.items.length;
    }
    final controller = ref.read(selectionProvider.notifier);

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _Header(
            filterActive: _notOnPhoneOnly,
            selecting: selection.active,
            onFilter: () => setState(() => _notOnPhoneOnly = !_notOnPhoneOnly),
            onSelect: () =>
                selection.active ? controller.exit() : controller.enter(),
          ),
          Expanded(
            child: Listener(
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              child: RefreshIndicator(
                key: const Key('timelineRefresh'),
                color: Tokens.accent,
                backgroundColor: Tokens.surface,
                onRefresh: _refresh,
                child: _body(data, display, selection),
              ),
            ),
          ),
          if (selection.active)
            SelectionBar(resolve: (keys) => _resolve(sections, keys)),
        ],
      ),
    );
  }

  Widget _body(
    AsyncValue<TimelineData> data,
    List<DisplaySection> display,
    SelectionState selection,
  ) {
    if (display.isEmpty) {
      _rows = const [];
      _starts = const [];
      String? text;
      if (data.isLoading || (data.value?.loading ?? false)) {
        text = null;
      } else if (data.hasError && !data.hasValue) {
        text = 'Could not load your photos.';
      } else {
        text = _notOnPhoneOnly
            ? 'Everything on your server is on this phone.'
            : 'No photos yet.';
      }
      // Scrollable, so pull-to-refresh works on an empty timeline too.
      return LayoutBuilder(
        builder: (context, box) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: box.maxHeight,
              child: text == null ? null : _Empty(text),
            ),
          ],
        ),
      );
    }
    final headerExtent = timelineHeaderExtent(MediaQuery.textScalerOf(context));
    return LayoutBuilder(
      builder: (context, box) {
        final rows = layoutRows(display, _columns);
        final tile = (box.maxWidth - timelineGap * (_columns - 1)) / _columns;
        final rowExtent = tile + timelineGap;
        final starts = List<double>.filled(rows.length, 0);
        var y = 0.0;
        for (var i = 0; i < rows.length; i++) {
          starts[i] = y;
          y += rows[i] is HeaderRow ? headerExtent : rowExtent;
        }
        _rows = rows;
        _starts = starts;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _updateWindow();
        });
        final controller = ref.read(selectionProvider.notifier);
        return ListView.builder(
          key: const Key('timelineList'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: rows.length,
          itemExtentBuilder: (i, _) =>
              rows[i] is HeaderRow ? headerExtent : rowExtent,
          itemBuilder: (context, i) {
            final row = rows[i];
            return switch (row) {
              HeaderRow() => SectionHeader(row),
              PlaceholderRow() => PlaceholderRowView(row: row, tileSize: tile),
              TilesRow() => TileRowView(
                row: row,
                tileSize: tile,
                selecting: selection.active,
                selectedKeys: selection.keys,
                onTap: (item) => selection.active
                    ? controller.toggle(item.key)
                    : context.push('/photos/${Uri.encodeComponent(item.key)}'),
                onLongPress: (item) => selection.active
                    ? controller.toggle(item.key)
                    : controller.enter(item.key),
              ),
            };
          },
        );
      },
    );
  }

  List<TimelineItem> _resolve(
    List<TimelineSection> sections,
    Set<String> keys,
  ) {
    return [
      for (final s in sections)
        for (final it in s.items)
          if (keys.contains(it.key)) it,
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.filterActive,
    required this.selecting,
    required this.onFilter,
    required this.onSelect,
  });

  final bool filterActive;
  final bool selecting;
  final VoidCallback onFilter;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 10, 4),
    child: Row(
      children: [
        Expanded(child: Text('Photos', style: displayStyle())),
        _RoundButton(
          tooltip: 'Show only photos not on this phone',
          draw: drawCloudIcon,
          active: filterActive,
          onTap: onFilter,
        ),
        _RoundButton(
          tooltip: 'Select',
          draw: drawCheckCircleIcon,
          active: selecting,
          onTap: onSelect,
        ),
      ],
    ),
  );
}

/// 44px round icon button inside a 48dp touch target.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.draw,
    required this.active,
    required this.onTap,
  });

  final String tooltip;
  final void Function(Canvas, Paint) draw;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: active,
    label: tooltip,
    excludeSemantics: true,
    child: Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 26,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                color: Tokens.surface,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: StrokeIcon(
                draw,
                color: active ? Tokens.accent : Tokens.text,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(text, style: bodyStyle(size: 15, color: Tokens.muted)),
  );
}
