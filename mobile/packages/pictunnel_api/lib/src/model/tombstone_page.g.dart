// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tombstone_page.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$TombstonePage extends TombstonePage {
  @override
  final BuiltList<Tombstone> tombstones;
  @override
  final String? nextCursor;
  @override
  final bool hasMore;

  factory _$TombstonePage([void Function(TombstonePageBuilder)? updates]) =>
      (TombstonePageBuilder()..update(updates))._build();

  _$TombstonePage._(
      {required this.tombstones, this.nextCursor, required this.hasMore})
      : super._();
  @override
  TombstonePage rebuild(void Function(TombstonePageBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  TombstonePageBuilder toBuilder() => TombstonePageBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is TombstonePage &&
        tombstones == other.tombstones &&
        nextCursor == other.nextCursor &&
        hasMore == other.hasMore;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, tombstones.hashCode);
    _$hash = $jc(_$hash, nextCursor.hashCode);
    _$hash = $jc(_$hash, hasMore.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'TombstonePage')
          ..add('tombstones', tombstones)
          ..add('nextCursor', nextCursor)
          ..add('hasMore', hasMore))
        .toString();
  }
}

class TombstonePageBuilder
    implements Builder<TombstonePage, TombstonePageBuilder> {
  _$TombstonePage? _$v;

  ListBuilder<Tombstone>? _tombstones;
  ListBuilder<Tombstone> get tombstones =>
      _$this._tombstones ??= ListBuilder<Tombstone>();
  set tombstones(ListBuilder<Tombstone>? tombstones) =>
      _$this._tombstones = tombstones;

  String? _nextCursor;
  String? get nextCursor => _$this._nextCursor;
  set nextCursor(String? nextCursor) => _$this._nextCursor = nextCursor;

  bool? _hasMore;
  bool? get hasMore => _$this._hasMore;
  set hasMore(bool? hasMore) => _$this._hasMore = hasMore;

  TombstonePageBuilder() {
    TombstonePage._defaults(this);
  }

  TombstonePageBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _tombstones = $v.tombstones.toBuilder();
      _nextCursor = $v.nextCursor;
      _hasMore = $v.hasMore;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(TombstonePage other) {
    _$v = other as _$TombstonePage;
  }

  @override
  void update(void Function(TombstonePageBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  TombstonePage build() => _build();

  _$TombstonePage _build() {
    _$TombstonePage _$result;
    try {
      _$result = _$v ??
          _$TombstonePage._(
            tombstones: tombstones.build(),
            nextCursor: nextCursor,
            hasMore: BuiltValueNullFieldError.checkNotNull(
                hasMore, r'TombstonePage', 'hasMore'),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'tombstones';
        tombstones.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'TombstonePage', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
