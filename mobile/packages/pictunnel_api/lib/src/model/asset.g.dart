// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'asset.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$Asset extends Asset {
  @override
  final String id;
  @override
  final String sha256;
  @override
  final int sizeBytes;
  @override
  final String mime;
  @override
  final String kind;
  @override
  final String filename;
  @override
  final DateTime? takenAt;
  @override
  final int? takenAtOffsetMinutes;
  @override
  final String takenAtSource;
  @override
  final int? width;
  @override
  final int? height;
  @override
  final int? durationMs;
  @override
  final double? lat;
  @override
  final double? lon;
  @override
  final String state;
  @override
  final DateTime? trashedAt;
  @override
  final String? stackId;
  @override
  final LiveVideo? liveVideo;
  @override
  final bool thumbnailsReady;
  @override
  final DateTime createdAt;
  @override
  final int updatedSeq;

  factory _$Asset([void Function(AssetBuilder)? updates]) =>
      (AssetBuilder()..update(updates))._build();

  _$Asset._(
      {required this.id,
      required this.sha256,
      required this.sizeBytes,
      required this.mime,
      required this.kind,
      required this.filename,
      this.takenAt,
      this.takenAtOffsetMinutes,
      required this.takenAtSource,
      this.width,
      this.height,
      this.durationMs,
      this.lat,
      this.lon,
      required this.state,
      this.trashedAt,
      this.stackId,
      this.liveVideo,
      required this.thumbnailsReady,
      required this.createdAt,
      required this.updatedSeq})
      : super._();
  @override
  Asset rebuild(void Function(AssetBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  AssetBuilder toBuilder() => AssetBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is Asset &&
        id == other.id &&
        sha256 == other.sha256 &&
        sizeBytes == other.sizeBytes &&
        mime == other.mime &&
        kind == other.kind &&
        filename == other.filename &&
        takenAt == other.takenAt &&
        takenAtOffsetMinutes == other.takenAtOffsetMinutes &&
        takenAtSource == other.takenAtSource &&
        width == other.width &&
        height == other.height &&
        durationMs == other.durationMs &&
        lat == other.lat &&
        lon == other.lon &&
        state == other.state &&
        trashedAt == other.trashedAt &&
        stackId == other.stackId &&
        liveVideo == other.liveVideo &&
        thumbnailsReady == other.thumbnailsReady &&
        createdAt == other.createdAt &&
        updatedSeq == other.updatedSeq;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, id.hashCode);
    _$hash = $jc(_$hash, sha256.hashCode);
    _$hash = $jc(_$hash, sizeBytes.hashCode);
    _$hash = $jc(_$hash, mime.hashCode);
    _$hash = $jc(_$hash, kind.hashCode);
    _$hash = $jc(_$hash, filename.hashCode);
    _$hash = $jc(_$hash, takenAt.hashCode);
    _$hash = $jc(_$hash, takenAtOffsetMinutes.hashCode);
    _$hash = $jc(_$hash, takenAtSource.hashCode);
    _$hash = $jc(_$hash, width.hashCode);
    _$hash = $jc(_$hash, height.hashCode);
    _$hash = $jc(_$hash, durationMs.hashCode);
    _$hash = $jc(_$hash, lat.hashCode);
    _$hash = $jc(_$hash, lon.hashCode);
    _$hash = $jc(_$hash, state.hashCode);
    _$hash = $jc(_$hash, trashedAt.hashCode);
    _$hash = $jc(_$hash, stackId.hashCode);
    _$hash = $jc(_$hash, liveVideo.hashCode);
    _$hash = $jc(_$hash, thumbnailsReady.hashCode);
    _$hash = $jc(_$hash, createdAt.hashCode);
    _$hash = $jc(_$hash, updatedSeq.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'Asset')
          ..add('id', id)
          ..add('sha256', sha256)
          ..add('sizeBytes', sizeBytes)
          ..add('mime', mime)
          ..add('kind', kind)
          ..add('filename', filename)
          ..add('takenAt', takenAt)
          ..add('takenAtOffsetMinutes', takenAtOffsetMinutes)
          ..add('takenAtSource', takenAtSource)
          ..add('width', width)
          ..add('height', height)
          ..add('durationMs', durationMs)
          ..add('lat', lat)
          ..add('lon', lon)
          ..add('state', state)
          ..add('trashedAt', trashedAt)
          ..add('stackId', stackId)
          ..add('liveVideo', liveVideo)
          ..add('thumbnailsReady', thumbnailsReady)
          ..add('createdAt', createdAt)
          ..add('updatedSeq', updatedSeq))
        .toString();
  }
}

class AssetBuilder implements Builder<Asset, AssetBuilder> {
  _$Asset? _$v;

  String? _id;
  String? get id => _$this._id;
  set id(String? id) => _$this._id = id;

  String? _sha256;
  String? get sha256 => _$this._sha256;
  set sha256(String? sha256) => _$this._sha256 = sha256;

  int? _sizeBytes;
  int? get sizeBytes => _$this._sizeBytes;
  set sizeBytes(int? sizeBytes) => _$this._sizeBytes = sizeBytes;

  String? _mime;
  String? get mime => _$this._mime;
  set mime(String? mime) => _$this._mime = mime;

  String? _kind;
  String? get kind => _$this._kind;
  set kind(String? kind) => _$this._kind = kind;

  String? _filename;
  String? get filename => _$this._filename;
  set filename(String? filename) => _$this._filename = filename;

  DateTime? _takenAt;
  DateTime? get takenAt => _$this._takenAt;
  set takenAt(DateTime? takenAt) => _$this._takenAt = takenAt;

  int? _takenAtOffsetMinutes;
  int? get takenAtOffsetMinutes => _$this._takenAtOffsetMinutes;
  set takenAtOffsetMinutes(int? takenAtOffsetMinutes) =>
      _$this._takenAtOffsetMinutes = takenAtOffsetMinutes;

  String? _takenAtSource;
  String? get takenAtSource => _$this._takenAtSource;
  set takenAtSource(String? takenAtSource) =>
      _$this._takenAtSource = takenAtSource;

  int? _width;
  int? get width => _$this._width;
  set width(int? width) => _$this._width = width;

  int? _height;
  int? get height => _$this._height;
  set height(int? height) => _$this._height = height;

  int? _durationMs;
  int? get durationMs => _$this._durationMs;
  set durationMs(int? durationMs) => _$this._durationMs = durationMs;

  double? _lat;
  double? get lat => _$this._lat;
  set lat(double? lat) => _$this._lat = lat;

  double? _lon;
  double? get lon => _$this._lon;
  set lon(double? lon) => _$this._lon = lon;

  String? _state;
  String? get state => _$this._state;
  set state(String? state) => _$this._state = state;

  DateTime? _trashedAt;
  DateTime? get trashedAt => _$this._trashedAt;
  set trashedAt(DateTime? trashedAt) => _$this._trashedAt = trashedAt;

  String? _stackId;
  String? get stackId => _$this._stackId;
  set stackId(String? stackId) => _$this._stackId = stackId;

  LiveVideoBuilder? _liveVideo;
  LiveVideoBuilder get liveVideo => _$this._liveVideo ??= LiveVideoBuilder();
  set liveVideo(LiveVideoBuilder? liveVideo) => _$this._liveVideo = liveVideo;

  bool? _thumbnailsReady;
  bool? get thumbnailsReady => _$this._thumbnailsReady;
  set thumbnailsReady(bool? thumbnailsReady) =>
      _$this._thumbnailsReady = thumbnailsReady;

  DateTime? _createdAt;
  DateTime? get createdAt => _$this._createdAt;
  set createdAt(DateTime? createdAt) => _$this._createdAt = createdAt;

  int? _updatedSeq;
  int? get updatedSeq => _$this._updatedSeq;
  set updatedSeq(int? updatedSeq) => _$this._updatedSeq = updatedSeq;

  AssetBuilder() {
    Asset._defaults(this);
  }

  AssetBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _id = $v.id;
      _sha256 = $v.sha256;
      _sizeBytes = $v.sizeBytes;
      _mime = $v.mime;
      _kind = $v.kind;
      _filename = $v.filename;
      _takenAt = $v.takenAt;
      _takenAtOffsetMinutes = $v.takenAtOffsetMinutes;
      _takenAtSource = $v.takenAtSource;
      _width = $v.width;
      _height = $v.height;
      _durationMs = $v.durationMs;
      _lat = $v.lat;
      _lon = $v.lon;
      _state = $v.state;
      _trashedAt = $v.trashedAt;
      _stackId = $v.stackId;
      _liveVideo = $v.liveVideo?.toBuilder();
      _thumbnailsReady = $v.thumbnailsReady;
      _createdAt = $v.createdAt;
      _updatedSeq = $v.updatedSeq;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(Asset other) {
    _$v = other as _$Asset;
  }

  @override
  void update(void Function(AssetBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  Asset build() => _build();

  _$Asset _build() {
    _$Asset _$result;
    try {
      _$result = _$v ??
          _$Asset._(
            id: BuiltValueNullFieldError.checkNotNull(id, r'Asset', 'id'),
            sha256: BuiltValueNullFieldError.checkNotNull(
                sha256, r'Asset', 'sha256'),
            sizeBytes: BuiltValueNullFieldError.checkNotNull(
                sizeBytes, r'Asset', 'sizeBytes'),
            mime: BuiltValueNullFieldError.checkNotNull(mime, r'Asset', 'mime'),
            kind: BuiltValueNullFieldError.checkNotNull(kind, r'Asset', 'kind'),
            filename: BuiltValueNullFieldError.checkNotNull(
                filename, r'Asset', 'filename'),
            takenAt: takenAt,
            takenAtOffsetMinutes: takenAtOffsetMinutes,
            takenAtSource: BuiltValueNullFieldError.checkNotNull(
                takenAtSource, r'Asset', 'takenAtSource'),
            width: width,
            height: height,
            durationMs: durationMs,
            lat: lat,
            lon: lon,
            state:
                BuiltValueNullFieldError.checkNotNull(state, r'Asset', 'state'),
            trashedAt: trashedAt,
            stackId: stackId,
            liveVideo: _liveVideo?.build(),
            thumbnailsReady: BuiltValueNullFieldError.checkNotNull(
                thumbnailsReady, r'Asset', 'thumbnailsReady'),
            createdAt: BuiltValueNullFieldError.checkNotNull(
                createdAt, r'Asset', 'createdAt'),
            updatedSeq: BuiltValueNullFieldError.checkNotNull(
                updatedSeq, r'Asset', 'updatedSeq'),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'liveVideo';
        _liveVideo?.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(r'Asset', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
