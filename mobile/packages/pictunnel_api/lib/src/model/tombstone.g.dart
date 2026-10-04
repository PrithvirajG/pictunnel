// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tombstone.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$Tombstone extends Tombstone {
  @override
  final String sha256;
  @override
  final String filename;
  @override
  final DateTime deletedAt;

  factory _$Tombstone([void Function(TombstoneBuilder)? updates]) =>
      (TombstoneBuilder()..update(updates))._build();

  _$Tombstone._(
      {required this.sha256, required this.filename, required this.deletedAt})
      : super._();
  @override
  Tombstone rebuild(void Function(TombstoneBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  TombstoneBuilder toBuilder() => TombstoneBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is Tombstone &&
        sha256 == other.sha256 &&
        filename == other.filename &&
        deletedAt == other.deletedAt;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, sha256.hashCode);
    _$hash = $jc(_$hash, filename.hashCode);
    _$hash = $jc(_$hash, deletedAt.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'Tombstone')
          ..add('sha256', sha256)
          ..add('filename', filename)
          ..add('deletedAt', deletedAt))
        .toString();
  }
}

class TombstoneBuilder implements Builder<Tombstone, TombstoneBuilder> {
  _$Tombstone? _$v;

  String? _sha256;
  String? get sha256 => _$this._sha256;
  set sha256(String? sha256) => _$this._sha256 = sha256;

  String? _filename;
  String? get filename => _$this._filename;
  set filename(String? filename) => _$this._filename = filename;

  DateTime? _deletedAt;
  DateTime? get deletedAt => _$this._deletedAt;
  set deletedAt(DateTime? deletedAt) => _$this._deletedAt = deletedAt;

  TombstoneBuilder() {
    Tombstone._defaults(this);
  }

  TombstoneBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _sha256 = $v.sha256;
      _filename = $v.filename;
      _deletedAt = $v.deletedAt;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(Tombstone other) {
    _$v = other as _$Tombstone;
  }

  @override
  void update(void Function(TombstoneBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  Tombstone build() => _build();

  _$Tombstone _build() {
    final _$result = _$v ??
        _$Tombstone._(
          sha256: BuiltValueNullFieldError.checkNotNull(
              sha256, r'Tombstone', 'sha256'),
          filename: BuiltValueNullFieldError.checkNotNull(
              filename, r'Tombstone', 'filename'),
          deletedAt: BuiltValueNullFieldError.checkNotNull(
              deletedAt, r'Tombstone', 'deletedAt'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
