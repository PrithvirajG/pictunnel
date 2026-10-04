// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'upload_limits.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$UploadLimits extends UploadLimits {
  @override
  final String tusVersion;
  @override
  final int maxFileBytes;
  @override
  final int recommendedChunkBytes;

  factory _$UploadLimits([void Function(UploadLimitsBuilder)? updates]) =>
      (UploadLimitsBuilder()..update(updates))._build();

  _$UploadLimits._(
      {required this.tusVersion,
      required this.maxFileBytes,
      required this.recommendedChunkBytes})
      : super._();
  @override
  UploadLimits rebuild(void Function(UploadLimitsBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  UploadLimitsBuilder toBuilder() => UploadLimitsBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is UploadLimits &&
        tusVersion == other.tusVersion &&
        maxFileBytes == other.maxFileBytes &&
        recommendedChunkBytes == other.recommendedChunkBytes;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, tusVersion.hashCode);
    _$hash = $jc(_$hash, maxFileBytes.hashCode);
    _$hash = $jc(_$hash, recommendedChunkBytes.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'UploadLimits')
          ..add('tusVersion', tusVersion)
          ..add('maxFileBytes', maxFileBytes)
          ..add('recommendedChunkBytes', recommendedChunkBytes))
        .toString();
  }
}

class UploadLimitsBuilder
    implements Builder<UploadLimits, UploadLimitsBuilder> {
  _$UploadLimits? _$v;

  String? _tusVersion;
  String? get tusVersion => _$this._tusVersion;
  set tusVersion(String? tusVersion) => _$this._tusVersion = tusVersion;

  int? _maxFileBytes;
  int? get maxFileBytes => _$this._maxFileBytes;
  set maxFileBytes(int? maxFileBytes) => _$this._maxFileBytes = maxFileBytes;

  int? _recommendedChunkBytes;
  int? get recommendedChunkBytes => _$this._recommendedChunkBytes;
  set recommendedChunkBytes(int? recommendedChunkBytes) =>
      _$this._recommendedChunkBytes = recommendedChunkBytes;

  UploadLimitsBuilder() {
    UploadLimits._defaults(this);
  }

  UploadLimitsBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _tusVersion = $v.tusVersion;
      _maxFileBytes = $v.maxFileBytes;
      _recommendedChunkBytes = $v.recommendedChunkBytes;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(UploadLimits other) {
    _$v = other as _$UploadLimits;
  }

  @override
  void update(void Function(UploadLimitsBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  UploadLimits build() => _build();

  _$UploadLimits _build() {
    final _$result = _$v ??
        _$UploadLimits._(
          tusVersion: BuiltValueNullFieldError.checkNotNull(
              tusVersion, r'UploadLimits', 'tusVersion'),
          maxFileBytes: BuiltValueNullFieldError.checkNotNull(
              maxFileBytes, r'UploadLimits', 'maxFileBytes'),
          recommendedChunkBytes: BuiltValueNullFieldError.checkNotNull(
              recommendedChunkBytes, r'UploadLimits', 'recommendedChunkBytes'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
