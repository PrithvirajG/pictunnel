// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'snapshot_page.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$SnapshotPage extends SnapshotPage {
  @override
  final String? cursor;
  @override
  final BuiltList<Asset> assets;
  @override
  final String? nextPageToken;
  @override
  final bool hasMore;

  factory _$SnapshotPage([void Function(SnapshotPageBuilder)? updates]) =>
      (SnapshotPageBuilder()..update(updates))._build();

  _$SnapshotPage._(
      {this.cursor,
      required this.assets,
      this.nextPageToken,
      required this.hasMore})
      : super._();
  @override
  SnapshotPage rebuild(void Function(SnapshotPageBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  SnapshotPageBuilder toBuilder() => SnapshotPageBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is SnapshotPage &&
        cursor == other.cursor &&
        assets == other.assets &&
        nextPageToken == other.nextPageToken &&
        hasMore == other.hasMore;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, cursor.hashCode);
    _$hash = $jc(_$hash, assets.hashCode);
    _$hash = $jc(_$hash, nextPageToken.hashCode);
    _$hash = $jc(_$hash, hasMore.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'SnapshotPage')
          ..add('cursor', cursor)
          ..add('assets', assets)
          ..add('nextPageToken', nextPageToken)
          ..add('hasMore', hasMore))
        .toString();
  }
}

class SnapshotPageBuilder
    implements Builder<SnapshotPage, SnapshotPageBuilder> {
  _$SnapshotPage? _$v;

  String? _cursor;
  String? get cursor => _$this._cursor;
  set cursor(String? cursor) => _$this._cursor = cursor;

  ListBuilder<Asset>? _assets;
  ListBuilder<Asset> get assets => _$this._assets ??= ListBuilder<Asset>();
  set assets(ListBuilder<Asset>? assets) => _$this._assets = assets;

  String? _nextPageToken;
  String? get nextPageToken => _$this._nextPageToken;
  set nextPageToken(String? nextPageToken) =>
      _$this._nextPageToken = nextPageToken;

  bool? _hasMore;
  bool? get hasMore => _$this._hasMore;
  set hasMore(bool? hasMore) => _$this._hasMore = hasMore;

  SnapshotPageBuilder() {
    SnapshotPage._defaults(this);
  }

  SnapshotPageBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _cursor = $v.cursor;
      _assets = $v.assets.toBuilder();
      _nextPageToken = $v.nextPageToken;
      _hasMore = $v.hasMore;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(SnapshotPage other) {
    _$v = other as _$SnapshotPage;
  }

  @override
  void update(void Function(SnapshotPageBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  SnapshotPage build() => _build();

  _$SnapshotPage _build() {
    _$SnapshotPage _$result;
    try {
      _$result = _$v ??
          _$SnapshotPage._(
            cursor: cursor,
            assets: assets.build(),
            nextPageToken: nextPageToken,
            hasMore: BuiltValueNullFieldError.checkNotNull(
                hasMore, r'SnapshotPage', 'hasMore'),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'assets';
        assets.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'SnapshotPage', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
