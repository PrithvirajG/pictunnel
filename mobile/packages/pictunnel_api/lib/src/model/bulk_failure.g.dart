// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bulk_failure.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$BulkFailure extends BulkFailure {
  @override
  final String assetId;
  @override
  final String code;

  factory _$BulkFailure([void Function(BulkFailureBuilder)? updates]) =>
      (BulkFailureBuilder()..update(updates))._build();

  _$BulkFailure._({required this.assetId, required this.code}) : super._();
  @override
  BulkFailure rebuild(void Function(BulkFailureBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  BulkFailureBuilder toBuilder() => BulkFailureBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is BulkFailure &&
        assetId == other.assetId &&
        code == other.code;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, assetId.hashCode);
    _$hash = $jc(_$hash, code.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'BulkFailure')
          ..add('assetId', assetId)
          ..add('code', code))
        .toString();
  }
}

class BulkFailureBuilder implements Builder<BulkFailure, BulkFailureBuilder> {
  _$BulkFailure? _$v;

  String? _assetId;
  String? get assetId => _$this._assetId;
  set assetId(String? assetId) => _$this._assetId = assetId;

  String? _code;
  String? get code => _$this._code;
  set code(String? code) => _$this._code = code;

  BulkFailureBuilder() {
    BulkFailure._defaults(this);
  }

  BulkFailureBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _assetId = $v.assetId;
      _code = $v.code;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(BulkFailure other) {
    _$v = other as _$BulkFailure;
  }

  @override
  void update(void Function(BulkFailureBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  BulkFailure build() => _build();

  _$BulkFailure _build() {
    final _$result = _$v ??
        _$BulkFailure._(
          assetId: BuiltValueNullFieldError.checkNotNull(
              assetId, r'BulkFailure', 'assetId'),
          code: BuiltValueNullFieldError.checkNotNull(
              code, r'BulkFailure', 'code'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
