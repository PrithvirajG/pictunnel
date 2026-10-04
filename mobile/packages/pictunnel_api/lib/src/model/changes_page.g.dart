// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'changes_page.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$ChangesPage extends ChangesPage {
  @override
  final BuiltList<ChangeEntry> changes;
  @override
  final String nextCursor;
  @override
  final bool hasMore;

  factory _$ChangesPage([void Function(ChangesPageBuilder)? updates]) =>
      (ChangesPageBuilder()..update(updates))._build();

  _$ChangesPage._(
      {required this.changes, required this.nextCursor, required this.hasMore})
      : super._();
  @override
  ChangesPage rebuild(void Function(ChangesPageBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  ChangesPageBuilder toBuilder() => ChangesPageBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is ChangesPage &&
        changes == other.changes &&
        nextCursor == other.nextCursor &&
        hasMore == other.hasMore;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, changes.hashCode);
    _$hash = $jc(_$hash, nextCursor.hashCode);
    _$hash = $jc(_$hash, hasMore.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'ChangesPage')
          ..add('changes', changes)
          ..add('nextCursor', nextCursor)
          ..add('hasMore', hasMore))
        .toString();
  }
}

class ChangesPageBuilder implements Builder<ChangesPage, ChangesPageBuilder> {
  _$ChangesPage? _$v;

  ListBuilder<ChangeEntry>? _changes;
  ListBuilder<ChangeEntry> get changes =>
      _$this._changes ??= ListBuilder<ChangeEntry>();
  set changes(ListBuilder<ChangeEntry>? changes) => _$this._changes = changes;

  String? _nextCursor;
  String? get nextCursor => _$this._nextCursor;
  set nextCursor(String? nextCursor) => _$this._nextCursor = nextCursor;

  bool? _hasMore;
  bool? get hasMore => _$this._hasMore;
  set hasMore(bool? hasMore) => _$this._hasMore = hasMore;

  ChangesPageBuilder() {
    ChangesPage._defaults(this);
  }

  ChangesPageBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _changes = $v.changes.toBuilder();
      _nextCursor = $v.nextCursor;
      _hasMore = $v.hasMore;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(ChangesPage other) {
    _$v = other as _$ChangesPage;
  }

  @override
  void update(void Function(ChangesPageBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  ChangesPage build() => _build();

  _$ChangesPage _build() {
    _$ChangesPage _$result;
    try {
      _$result = _$v ??
          _$ChangesPage._(
            changes: changes.build(),
            nextCursor: BuiltValueNullFieldError.checkNotNull(
                nextCursor, r'ChangesPage', 'nextCursor'),
            hasMore: BuiltValueNullFieldError.checkNotNull(
                hasMore, r'ChangesPage', 'hasMore'),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'changes';
        changes.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'ChangesPage', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
