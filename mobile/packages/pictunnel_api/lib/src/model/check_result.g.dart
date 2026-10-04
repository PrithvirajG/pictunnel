// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'check_result.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$CheckResult extends CheckResult {
  @override
  final String sha256;
  @override
  final String verdict;
  @override
  final String? assetId;
  @override
  final String? assetState;
  @override
  final bool? hasLiveVideo;
  @override
  final bool? onDisk;
  @override
  final UploadRef? upload;
  @override
  final DateTime? deletedAt;

  factory _$CheckResult([void Function(CheckResultBuilder)? updates]) =>
      (CheckResultBuilder()..update(updates))._build();

  _$CheckResult._(
      {required this.sha256,
      required this.verdict,
      this.assetId,
      this.assetState,
      this.hasLiveVideo,
      this.onDisk,
      this.upload,
      this.deletedAt})
      : super._();
  @override
  CheckResult rebuild(void Function(CheckResultBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  CheckResultBuilder toBuilder() => CheckResultBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is CheckResult &&
        sha256 == other.sha256 &&
        verdict == other.verdict &&
        assetId == other.assetId &&
        assetState == other.assetState &&
        hasLiveVideo == other.hasLiveVideo &&
        onDisk == other.onDisk &&
        upload == other.upload &&
        deletedAt == other.deletedAt;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, sha256.hashCode);
    _$hash = $jc(_$hash, verdict.hashCode);
    _$hash = $jc(_$hash, assetId.hashCode);
    _$hash = $jc(_$hash, assetState.hashCode);
    _$hash = $jc(_$hash, hasLiveVideo.hashCode);
    _$hash = $jc(_$hash, onDisk.hashCode);
    _$hash = $jc(_$hash, upload.hashCode);
    _$hash = $jc(_$hash, deletedAt.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'CheckResult')
          ..add('sha256', sha256)
          ..add('verdict', verdict)
          ..add('assetId', assetId)
          ..add('assetState', assetState)
          ..add('hasLiveVideo', hasLiveVideo)
          ..add('onDisk', onDisk)
          ..add('upload', upload)
          ..add('deletedAt', deletedAt))
        .toString();
  }
}

class CheckResultBuilder implements Builder<CheckResult, CheckResultBuilder> {
  _$CheckResult? _$v;

  String? _sha256;
  String? get sha256 => _$this._sha256;
  set sha256(String? sha256) => _$this._sha256 = sha256;

  String? _verdict;
  String? get verdict => _$this._verdict;
  set verdict(String? verdict) => _$this._verdict = verdict;

  String? _assetId;
  String? get assetId => _$this._assetId;
  set assetId(String? assetId) => _$this._assetId = assetId;

  String? _assetState;
  String? get assetState => _$this._assetState;
  set assetState(String? assetState) => _$this._assetState = assetState;

  bool? _hasLiveVideo;
  bool? get hasLiveVideo => _$this._hasLiveVideo;
  set hasLiveVideo(bool? hasLiveVideo) => _$this._hasLiveVideo = hasLiveVideo;

  bool? _onDisk;
  bool? get onDisk => _$this._onDisk;
  set onDisk(bool? onDisk) => _$this._onDisk = onDisk;

  UploadRefBuilder? _upload;
  UploadRefBuilder get upload => _$this._upload ??= UploadRefBuilder();
  set upload(UploadRefBuilder? upload) => _$this._upload = upload;

  DateTime? _deletedAt;
  DateTime? get deletedAt => _$this._deletedAt;
  set deletedAt(DateTime? deletedAt) => _$this._deletedAt = deletedAt;

  CheckResultBuilder() {
    CheckResult._defaults(this);
  }

  CheckResultBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _sha256 = $v.sha256;
      _verdict = $v.verdict;
      _assetId = $v.assetId;
      _assetState = $v.assetState;
      _hasLiveVideo = $v.hasLiveVideo;
      _onDisk = $v.onDisk;
      _upload = $v.upload?.toBuilder();
      _deletedAt = $v.deletedAt;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(CheckResult other) {
    _$v = other as _$CheckResult;
  }

  @override
  void update(void Function(CheckResultBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  CheckResult build() => _build();

  _$CheckResult _build() {
    _$CheckResult _$result;
    try {
      _$result = _$v ??
          _$CheckResult._(
            sha256: BuiltValueNullFieldError.checkNotNull(
                sha256, r'CheckResult', 'sha256'),
            verdict: BuiltValueNullFieldError.checkNotNull(
                verdict, r'CheckResult', 'verdict'),
            assetId: assetId,
            assetState: assetState,
            hasLiveVideo: hasLiveVideo,
            onDisk: onDisk,
            upload: _upload?.build(),
            deletedAt: deletedAt,
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'upload';
        _upload?.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'CheckResult', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
