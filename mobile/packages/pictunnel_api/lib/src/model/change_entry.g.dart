// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'change_entry.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$ChangeEntry extends ChangeEntry {
  @override
  final int seq;
  @override
  final String kind;
  @override
  final Asset? asset;
  @override
  final String? assetId;

  factory _$ChangeEntry([void Function(ChangeEntryBuilder)? updates]) =>
      (ChangeEntryBuilder()..update(updates))._build();

  _$ChangeEntry._(
      {required this.seq, required this.kind, this.asset, this.assetId})
      : super._();
  @override
  ChangeEntry rebuild(void Function(ChangeEntryBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  ChangeEntryBuilder toBuilder() => ChangeEntryBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is ChangeEntry &&
        seq == other.seq &&
        kind == other.kind &&
        asset == other.asset &&
        assetId == other.assetId;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, seq.hashCode);
    _$hash = $jc(_$hash, kind.hashCode);
    _$hash = $jc(_$hash, asset.hashCode);
    _$hash = $jc(_$hash, assetId.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'ChangeEntry')
          ..add('seq', seq)
          ..add('kind', kind)
          ..add('asset', asset)
          ..add('assetId', assetId))
        .toString();
  }
}

class ChangeEntryBuilder implements Builder<ChangeEntry, ChangeEntryBuilder> {
  _$ChangeEntry? _$v;

  int? _seq;
  int? get seq => _$this._seq;
  set seq(int? seq) => _$this._seq = seq;

  String? _kind;
  String? get kind => _$this._kind;
  set kind(String? kind) => _$this._kind = kind;

  AssetBuilder? _asset;
  AssetBuilder get asset => _$this._asset ??= AssetBuilder();
  set asset(AssetBuilder? asset) => _$this._asset = asset;

  String? _assetId;
  String? get assetId => _$this._assetId;
  set assetId(String? assetId) => _$this._assetId = assetId;

  ChangeEntryBuilder() {
    ChangeEntry._defaults(this);
  }

  ChangeEntryBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _seq = $v.seq;
      _kind = $v.kind;
      _asset = $v.asset?.toBuilder();
      _assetId = $v.assetId;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(ChangeEntry other) {
    _$v = other as _$ChangeEntry;
  }

  @override
  void update(void Function(ChangeEntryBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  ChangeEntry build() => _build();

  _$ChangeEntry _build() {
    _$ChangeEntry _$result;
    try {
      _$result = _$v ??
          _$ChangeEntry._(
            seq: BuiltValueNullFieldError.checkNotNull(
                seq, r'ChangeEntry', 'seq'),
            kind: BuiltValueNullFieldError.checkNotNull(
                kind, r'ChangeEntry', 'kind'),
            asset: _asset?.build(),
            assetId: assetId,
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'asset';
        _asset?.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'ChangeEntry', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
