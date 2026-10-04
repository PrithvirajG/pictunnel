// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'check_item.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$CheckItem extends CheckItem {
  @override
  final String sha256;
  @override
  final int sizeBytes;
  @override
  final String? localId;
  @override
  final bool? confirmOnDisk;

  factory _$CheckItem([void Function(CheckItemBuilder)? updates]) =>
      (CheckItemBuilder()..update(updates))._build();

  _$CheckItem._(
      {required this.sha256,
      required this.sizeBytes,
      this.localId,
      this.confirmOnDisk})
      : super._();
  @override
  CheckItem rebuild(void Function(CheckItemBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  CheckItemBuilder toBuilder() => CheckItemBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is CheckItem &&
        sha256 == other.sha256 &&
        sizeBytes == other.sizeBytes &&
        localId == other.localId &&
        confirmOnDisk == other.confirmOnDisk;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, sha256.hashCode);
    _$hash = $jc(_$hash, sizeBytes.hashCode);
    _$hash = $jc(_$hash, localId.hashCode);
    _$hash = $jc(_$hash, confirmOnDisk.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'CheckItem')
          ..add('sha256', sha256)
          ..add('sizeBytes', sizeBytes)
          ..add('localId', localId)
          ..add('confirmOnDisk', confirmOnDisk))
        .toString();
  }
}

class CheckItemBuilder implements Builder<CheckItem, CheckItemBuilder> {
  _$CheckItem? _$v;

  String? _sha256;
  String? get sha256 => _$this._sha256;
  set sha256(String? sha256) => _$this._sha256 = sha256;

  int? _sizeBytes;
  int? get sizeBytes => _$this._sizeBytes;
  set sizeBytes(int? sizeBytes) => _$this._sizeBytes = sizeBytes;

  String? _localId;
  String? get localId => _$this._localId;
  set localId(String? localId) => _$this._localId = localId;

  bool? _confirmOnDisk;
  bool? get confirmOnDisk => _$this._confirmOnDisk;
  set confirmOnDisk(bool? confirmOnDisk) =>
      _$this._confirmOnDisk = confirmOnDisk;

  CheckItemBuilder() {
    CheckItem._defaults(this);
  }

  CheckItemBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _sha256 = $v.sha256;
      _sizeBytes = $v.sizeBytes;
      _localId = $v.localId;
      _confirmOnDisk = $v.confirmOnDisk;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(CheckItem other) {
    _$v = other as _$CheckItem;
  }

  @override
  void update(void Function(CheckItemBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  CheckItem build() => _build();

  _$CheckItem _build() {
    final _$result = _$v ??
        _$CheckItem._(
          sha256: BuiltValueNullFieldError.checkNotNull(
              sha256, r'CheckItem', 'sha256'),
          sizeBytes: BuiltValueNullFieldError.checkNotNull(
              sizeBytes, r'CheckItem', 'sizeBytes'),
          localId: localId,
          confirmOnDisk: confirmOnDisk,
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
