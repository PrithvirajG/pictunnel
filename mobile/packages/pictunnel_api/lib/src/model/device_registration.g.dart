// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_registration.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

const DeviceRegistrationPlatformEnum _$deviceRegistrationPlatformEnum_android =
    const DeviceRegistrationPlatformEnum._('android');
const DeviceRegistrationPlatformEnum _$deviceRegistrationPlatformEnum_ios =
    const DeviceRegistrationPlatformEnum._('ios');
const DeviceRegistrationPlatformEnum _$deviceRegistrationPlatformEnum_web =
    const DeviceRegistrationPlatformEnum._('web');
const DeviceRegistrationPlatformEnum _$deviceRegistrationPlatformEnum_other =
    const DeviceRegistrationPlatformEnum._('other');
const DeviceRegistrationPlatformEnum
    _$deviceRegistrationPlatformEnum_unknownDefaultOpenApi =
    const DeviceRegistrationPlatformEnum._('unknownDefaultOpenApi');

DeviceRegistrationPlatformEnum _$deviceRegistrationPlatformEnumValueOf(
    String name) {
  switch (name) {
    case 'android':
      return _$deviceRegistrationPlatformEnum_android;
    case 'ios':
      return _$deviceRegistrationPlatformEnum_ios;
    case 'web':
      return _$deviceRegistrationPlatformEnum_web;
    case 'other':
      return _$deviceRegistrationPlatformEnum_other;
    case 'unknownDefaultOpenApi':
      return _$deviceRegistrationPlatformEnum_unknownDefaultOpenApi;
    default:
      return _$deviceRegistrationPlatformEnum_unknownDefaultOpenApi;
  }
}

final BuiltSet<DeviceRegistrationPlatformEnum>
    _$deviceRegistrationPlatformEnumValues = BuiltSet<
        DeviceRegistrationPlatformEnum>(const <DeviceRegistrationPlatformEnum>[
  _$deviceRegistrationPlatformEnum_android,
  _$deviceRegistrationPlatformEnum_ios,
  _$deviceRegistrationPlatformEnum_web,
  _$deviceRegistrationPlatformEnum_other,
  _$deviceRegistrationPlatformEnum_unknownDefaultOpenApi,
]);

Serializer<DeviceRegistrationPlatformEnum>
    _$deviceRegistrationPlatformEnumSerializer =
    _$DeviceRegistrationPlatformEnumSerializer();

class _$DeviceRegistrationPlatformEnumSerializer
    implements PrimitiveSerializer<DeviceRegistrationPlatformEnum> {
  static const Map<String, Object> _toWire = const <String, Object>{
    'android': 'android',
    'ios': 'ios',
    'web': 'web',
    'other': 'other',
    'unknownDefaultOpenApi': 'unknown_default_open_api',
  };
  static const Map<Object, String> _fromWire = const <Object, String>{
    'android': 'android',
    'ios': 'ios',
    'web': 'web',
    'other': 'other',
    'unknown_default_open_api': 'unknownDefaultOpenApi',
  };

  @override
  final Iterable<Type> types = const <Type>[DeviceRegistrationPlatformEnum];
  @override
  final String wireName = 'DeviceRegistrationPlatformEnum';

  @override
  Object serialize(
          Serializers serializers, DeviceRegistrationPlatformEnum object,
          {FullType specifiedType = FullType.unspecified}) =>
      _toWire[object.name] ?? object.name;

  @override
  DeviceRegistrationPlatformEnum deserialize(
          Serializers serializers, Object serialized,
          {FullType specifiedType = FullType.unspecified}) =>
      DeviceRegistrationPlatformEnum.valueOf(
          _fromWire[serialized] ?? (serialized is String ? serialized : ''));
}

class _$DeviceRegistration extends DeviceRegistration {
  @override
  final String deviceName;
  @override
  final DeviceRegistrationPlatformEnum platform;
  @override
  final String appVersion;

  factory _$DeviceRegistration(
          [void Function(DeviceRegistrationBuilder)? updates]) =>
      (DeviceRegistrationBuilder()..update(updates))._build();

  _$DeviceRegistration._(
      {required this.deviceName,
      required this.platform,
      required this.appVersion})
      : super._();
  @override
  DeviceRegistration rebuild(
          void Function(DeviceRegistrationBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  DeviceRegistrationBuilder toBuilder() =>
      DeviceRegistrationBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is DeviceRegistration &&
        deviceName == other.deviceName &&
        platform == other.platform &&
        appVersion == other.appVersion;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, deviceName.hashCode);
    _$hash = $jc(_$hash, platform.hashCode);
    _$hash = $jc(_$hash, appVersion.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'DeviceRegistration')
          ..add('deviceName', deviceName)
          ..add('platform', platform)
          ..add('appVersion', appVersion))
        .toString();
  }
}

class DeviceRegistrationBuilder
    implements Builder<DeviceRegistration, DeviceRegistrationBuilder> {
  _$DeviceRegistration? _$v;

  String? _deviceName;
  String? get deviceName => _$this._deviceName;
  set deviceName(String? deviceName) => _$this._deviceName = deviceName;

  DeviceRegistrationPlatformEnum? _platform;
  DeviceRegistrationPlatformEnum? get platform => _$this._platform;
  set platform(DeviceRegistrationPlatformEnum? platform) =>
      _$this._platform = platform;

  String? _appVersion;
  String? get appVersion => _$this._appVersion;
  set appVersion(String? appVersion) => _$this._appVersion = appVersion;

  DeviceRegistrationBuilder() {
    DeviceRegistration._defaults(this);
  }

  DeviceRegistrationBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _deviceName = $v.deviceName;
      _platform = $v.platform;
      _appVersion = $v.appVersion;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(DeviceRegistration other) {
    _$v = other as _$DeviceRegistration;
  }

  @override
  void update(void Function(DeviceRegistrationBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  DeviceRegistration build() => _build();

  _$DeviceRegistration _build() {
    final _$result = _$v ??
        _$DeviceRegistration._(
          deviceName: BuiltValueNullFieldError.checkNotNull(
              deviceName, r'DeviceRegistration', 'deviceName'),
          platform: BuiltValueNullFieldError.checkNotNull(
              platform, r'DeviceRegistration', 'platform'),
          appVersion: BuiltValueNullFieldError.checkNotNull(
              appVersion, r'DeviceRegistration', 'appVersion'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
