// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'live_video.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$LiveVideo extends LiveVideo {
  @override
  final String sha256;
  @override
  final int sizeBytes;
  @override
  final String mime;

  factory _$LiveVideo([void Function(LiveVideoBuilder)? updates]) =>
      (LiveVideoBuilder()..update(updates))._build();

  _$LiveVideo._(
      {required this.sha256, required this.sizeBytes, required this.mime})
      : super._();
  @override
  LiveVideo rebuild(void Function(LiveVideoBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  LiveVideoBuilder toBuilder() => LiveVideoBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is LiveVideo &&
        sha256 == other.sha256 &&
        sizeBytes == other.sizeBytes &&
        mime == other.mime;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, sha256.hashCode);
    _$hash = $jc(_$hash, sizeBytes.hashCode);
    _$hash = $jc(_$hash, mime.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'LiveVideo')
          ..add('sha256', sha256)
          ..add('sizeBytes', sizeBytes)
          ..add('mime', mime))
        .toString();
  }
}

class LiveVideoBuilder implements Builder<LiveVideo, LiveVideoBuilder> {
  _$LiveVideo? _$v;

  String? _sha256;
  String? get sha256 => _$this._sha256;
  set sha256(String? sha256) => _$this._sha256 = sha256;

  int? _sizeBytes;
  int? get sizeBytes => _$this._sizeBytes;
  set sizeBytes(int? sizeBytes) => _$this._sizeBytes = sizeBytes;

  String? _mime;
  String? get mime => _$this._mime;
  set mime(String? mime) => _$this._mime = mime;

  LiveVideoBuilder() {
    LiveVideo._defaults(this);
  }

  LiveVideoBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _sha256 = $v.sha256;
      _sizeBytes = $v.sizeBytes;
      _mime = $v.mime;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(LiveVideo other) {
    _$v = other as _$LiveVideo;
  }

  @override
  void update(void Function(LiveVideoBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  LiveVideo build() => _build();

  _$LiveVideo _build() {
    final _$result = _$v ??
        _$LiveVideo._(
          sha256: BuiltValueNullFieldError.checkNotNull(
              sha256, r'LiveVideo', 'sha256'),
          sizeBytes: BuiltValueNullFieldError.checkNotNull(
              sizeBytes, r'LiveVideo', 'sizeBytes'),
          mime:
              BuiltValueNullFieldError.checkNotNull(mime, r'LiveVideo', 'mime'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
