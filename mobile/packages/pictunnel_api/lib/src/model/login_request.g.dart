// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'login_request.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

const LoginRequestModeEnum _$loginRequestModeEnum_tokens =
    const LoginRequestModeEnum._('tokens');
const LoginRequestModeEnum _$loginRequestModeEnum_cookie =
    const LoginRequestModeEnum._('cookie');
const LoginRequestModeEnum _$loginRequestModeEnum_unknownDefaultOpenApi =
    const LoginRequestModeEnum._('unknownDefaultOpenApi');

LoginRequestModeEnum _$loginRequestModeEnumValueOf(String name) {
  switch (name) {
    case 'tokens':
      return _$loginRequestModeEnum_tokens;
    case 'cookie':
      return _$loginRequestModeEnum_cookie;
    case 'unknownDefaultOpenApi':
      return _$loginRequestModeEnum_unknownDefaultOpenApi;
    default:
      return _$loginRequestModeEnum_unknownDefaultOpenApi;
  }
}

final BuiltSet<LoginRequestModeEnum> _$loginRequestModeEnumValues =
    BuiltSet<LoginRequestModeEnum>(const <LoginRequestModeEnum>[
  _$loginRequestModeEnum_tokens,
  _$loginRequestModeEnum_cookie,
  _$loginRequestModeEnum_unknownDefaultOpenApi,
]);

Serializer<LoginRequestModeEnum> _$loginRequestModeEnumSerializer =
    _$LoginRequestModeEnumSerializer();

class _$LoginRequestModeEnumSerializer
    implements PrimitiveSerializer<LoginRequestModeEnum> {
  static const Map<String, Object> _toWire = const <String, Object>{
    'tokens': 'tokens',
    'cookie': 'cookie',
    'unknownDefaultOpenApi': 'unknown_default_open_api',
  };
  static const Map<Object, String> _fromWire = const <Object, String>{
    'tokens': 'tokens',
    'cookie': 'cookie',
    'unknown_default_open_api': 'unknownDefaultOpenApi',
  };

  @override
  final Iterable<Type> types = const <Type>[LoginRequestModeEnum];
  @override
  final String wireName = 'LoginRequestModeEnum';

  @override
  Object serialize(Serializers serializers, LoginRequestModeEnum object,
          {FullType specifiedType = FullType.unspecified}) =>
      _toWire[object.name] ?? object.name;

  @override
  LoginRequestModeEnum deserialize(Serializers serializers, Object serialized,
          {FullType specifiedType = FullType.unspecified}) =>
      LoginRequestModeEnum.valueOf(
          _fromWire[serialized] ?? (serialized is String ? serialized : ''));
}

class _$LoginRequest extends LoginRequest {
  @override
  final String username;
  @override
  final String password;
  @override
  final LoginRequestModeEnum mode;
  @override
  final DeviceRegistration? device;

  factory _$LoginRequest([void Function(LoginRequestBuilder)? updates]) =>
      (LoginRequestBuilder()..update(updates))._build();

  _$LoginRequest._(
      {required this.username,
      required this.password,
      required this.mode,
      this.device})
      : super._();
  @override
  LoginRequest rebuild(void Function(LoginRequestBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  LoginRequestBuilder toBuilder() => LoginRequestBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is LoginRequest &&
        username == other.username &&
        password == other.password &&
        mode == other.mode &&
        device == other.device;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, username.hashCode);
    _$hash = $jc(_$hash, password.hashCode);
    _$hash = $jc(_$hash, mode.hashCode);
    _$hash = $jc(_$hash, device.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'LoginRequest')
          ..add('username', username)
          ..add('password', password)
          ..add('mode', mode)
          ..add('device', device))
        .toString();
  }
}

class LoginRequestBuilder
    implements Builder<LoginRequest, LoginRequestBuilder> {
  _$LoginRequest? _$v;

  String? _username;
  String? get username => _$this._username;
  set username(String? username) => _$this._username = username;

  String? _password;
  String? get password => _$this._password;
  set password(String? password) => _$this._password = password;

  LoginRequestModeEnum? _mode;
  LoginRequestModeEnum? get mode => _$this._mode;
  set mode(LoginRequestModeEnum? mode) => _$this._mode = mode;

  DeviceRegistrationBuilder? _device;
  DeviceRegistrationBuilder get device =>
      _$this._device ??= DeviceRegistrationBuilder();
  set device(DeviceRegistrationBuilder? device) => _$this._device = device;

  LoginRequestBuilder() {
    LoginRequest._defaults(this);
  }

  LoginRequestBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _username = $v.username;
      _password = $v.password;
      _mode = $v.mode;
      _device = $v.device?.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(LoginRequest other) {
    _$v = other as _$LoginRequest;
  }

  @override
  void update(void Function(LoginRequestBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  LoginRequest build() => _build();

  _$LoginRequest _build() {
    _$LoginRequest _$result;
    try {
      _$result = _$v ??
          _$LoginRequest._(
            username: BuiltValueNullFieldError.checkNotNull(
                username, r'LoginRequest', 'username'),
            password: BuiltValueNullFieldError.checkNotNull(
                password, r'LoginRequest', 'password'),
            mode: BuiltValueNullFieldError.checkNotNull(
                mode, r'LoginRequest', 'mode'),
            device: _device?.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'device';
        _device?.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'LoginRequest', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
