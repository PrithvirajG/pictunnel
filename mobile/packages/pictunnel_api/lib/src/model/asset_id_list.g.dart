// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'asset_id_list.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$AssetIdList extends AssetIdList {
  @override
  final BuiltList<String> assetIds;

  factory _$AssetIdList([void Function(AssetIdListBuilder)? updates]) =>
      (AssetIdListBuilder()..update(updates))._build();

  _$AssetIdList._({required this.assetIds}) : super._();
  @override
  AssetIdList rebuild(void Function(AssetIdListBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  AssetIdListBuilder toBuilder() => AssetIdListBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is AssetIdList && assetIds == other.assetIds;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, assetIds.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'AssetIdList')
          ..add('assetIds', assetIds))
        .toString();
  }
}

class AssetIdListBuilder implements Builder<AssetIdList, AssetIdListBuilder> {
  _$AssetIdList? _$v;

  ListBuilder<String>? _assetIds;
  ListBuilder<String> get assetIds =>
      _$this._assetIds ??= ListBuilder<String>();
  set assetIds(ListBuilder<String>? assetIds) => _$this._assetIds = assetIds;

  AssetIdListBuilder() {
    AssetIdList._defaults(this);
  }

  AssetIdListBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _assetIds = $v.assetIds.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(AssetIdList other) {
    _$v = other as _$AssetIdList;
  }

  @override
  void update(void Function(AssetIdListBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  AssetIdList build() => _build();

  _$AssetIdList _build() {
    _$AssetIdList _$result;
    try {
      _$result = _$v ??
          _$AssetIdList._(
            assetIds: assetIds.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'assetIds';
        assetIds.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'AssetIdList', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
