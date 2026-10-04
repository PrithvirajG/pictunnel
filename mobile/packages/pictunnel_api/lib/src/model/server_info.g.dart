// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_info.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$ServerInfo extends ServerInfo {
  @override
  final String serverId;
  @override
  final String name;
  @override
  final String version;
  @override
  final String apiVersion;
  @override
  final ClientVersions minClientVersion;
  @override
  final BuiltList<String> capabilities;
  @override
  final UploadLimits upload;
  @override
  final DateTime time;

  factory _$ServerInfo([void Function(ServerInfoBuilder)? updates]) =>
      (ServerInfoBuilder()..update(updates))._build();

  _$ServerInfo._(
      {required this.serverId,
      required this.name,
      required this.version,
      required this.apiVersion,
      required this.minClientVersion,
      required this.capabilities,
      required this.upload,
      required this.time})
      : super._();
  @override
  ServerInfo rebuild(void Function(ServerInfoBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  ServerInfoBuilder toBuilder() => ServerInfoBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is ServerInfo &&
        serverId == other.serverId &&
        name == other.name &&
        version == other.version &&
        apiVersion == other.apiVersion &&
        minClientVersion == other.minClientVersion &&
        capabilities == other.capabilities &&
        upload == other.upload &&
        time == other.time;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, serverId.hashCode);
    _$hash = $jc(_$hash, name.hashCode);
    _$hash = $jc(_$hash, version.hashCode);
    _$hash = $jc(_$hash, apiVersion.hashCode);
    _$hash = $jc(_$hash, minClientVersion.hashCode);
    _$hash = $jc(_$hash, capabilities.hashCode);
    _$hash = $jc(_$hash, upload.hashCode);
    _$hash = $jc(_$hash, time.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'ServerInfo')
          ..add('serverId', serverId)
          ..add('name', name)
          ..add('version', version)
          ..add('apiVersion', apiVersion)
          ..add('minClientVersion', minClientVersion)
          ..add('capabilities', capabilities)
          ..add('upload', upload)
          ..add('time', time))
        .toString();
  }
}

class ServerInfoBuilder implements Builder<ServerInfo, ServerInfoBuilder> {
  _$ServerInfo? _$v;

  String? _serverId;
  String? get serverId => _$this._serverId;
  set serverId(String? serverId) => _$this._serverId = serverId;

  String? _name;
  String? get name => _$this._name;
  set name(String? name) => _$this._name = name;

  String? _version;
  String? get version => _$this._version;
  set version(String? version) => _$this._version = version;

  String? _apiVersion;
  String? get apiVersion => _$this._apiVersion;
  set apiVersion(String? apiVersion) => _$this._apiVersion = apiVersion;

  ClientVersionsBuilder? _minClientVersion;
  ClientVersionsBuilder get minClientVersion =>
      _$this._minClientVersion ??= ClientVersionsBuilder();
  set minClientVersion(ClientVersionsBuilder? minClientVersion) =>
      _$this._minClientVersion = minClientVersion;

  ListBuilder<String>? _capabilities;
  ListBuilder<String> get capabilities =>
      _$this._capabilities ??= ListBuilder<String>();
  set capabilities(ListBuilder<String>? capabilities) =>
      _$this._capabilities = capabilities;

  UploadLimitsBuilder? _upload;
  UploadLimitsBuilder get upload => _$this._upload ??= UploadLimitsBuilder();
  set upload(UploadLimitsBuilder? upload) => _$this._upload = upload;

  DateTime? _time;
  DateTime? get time => _$this._time;
  set time(DateTime? time) => _$this._time = time;

  ServerInfoBuilder() {
    ServerInfo._defaults(this);
  }

  ServerInfoBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _serverId = $v.serverId;
      _name = $v.name;
      _version = $v.version;
      _apiVersion = $v.apiVersion;
      _minClientVersion = $v.minClientVersion.toBuilder();
      _capabilities = $v.capabilities.toBuilder();
      _upload = $v.upload.toBuilder();
      _time = $v.time;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(ServerInfo other) {
    _$v = other as _$ServerInfo;
  }

  @override
  void update(void Function(ServerInfoBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  ServerInfo build() => _build();

  _$ServerInfo _build() {
    _$ServerInfo _$result;
    try {
      _$result = _$v ??
          _$ServerInfo._(
            serverId: BuiltValueNullFieldError.checkNotNull(
                serverId, r'ServerInfo', 'serverId'),
            name: BuiltValueNullFieldError.checkNotNull(
                name, r'ServerInfo', 'name'),
            version: BuiltValueNullFieldError.checkNotNull(
                version, r'ServerInfo', 'version'),
            apiVersion: BuiltValueNullFieldError.checkNotNull(
                apiVersion, r'ServerInfo', 'apiVersion'),
            minClientVersion: minClientVersion.build(),
            capabilities: capabilities.build(),
            upload: upload.build(),
            time: BuiltValueNullFieldError.checkNotNull(
                time, r'ServerInfo', 'time'),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'minClientVersion';
        minClientVersion.build();
        _$failedField = 'capabilities';
        capabilities.build();
        _$failedField = 'upload';
        upload.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'ServerInfo', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
