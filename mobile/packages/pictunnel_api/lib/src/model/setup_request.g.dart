// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'setup_request.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$SetupRequest extends SetupRequest {
  @override
  final String username;
  @override
  final String password;
  @override
  final String? displayName;

  factory _$SetupRequest([void Function(SetupRequestBuilder)? updates]) =>
      (SetupRequestBuilder()..update(updates))._build();

  _$SetupRequest._(
      {required this.username, required this.password, this.displayName})
      : super._();
  @override
  SetupRequest rebuild(void Function(SetupRequestBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  SetupRequestBuilder toBuilder() => SetupRequestBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is SetupRequest &&
        username == other.username &&
        password == other.password &&
        displayName == other.displayName;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, username.hashCode);
    _$hash = $jc(_$hash, password.hashCode);
    _$hash = $jc(_$hash, displayName.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'SetupRequest')
          ..add('username', username)
          ..add('password', password)
          ..add('displayName', displayName))
        .toString();
  }
}

class SetupRequestBuilder
    implements Builder<SetupRequest, SetupRequestBuilder> {
  _$SetupRequest? _$v;

  String? _username;
  String? get username => _$this._username;
  set username(String? username) => _$this._username = username;

  String? _password;
  String? get password => _$this._password;
  set password(String? password) => _$this._password = password;

  String? _displayName;
  String? get displayName => _$this._displayName;
  set displayName(String? displayName) => _$this._displayName = displayName;

  SetupRequestBuilder() {
    SetupRequest._defaults(this);
  }

  SetupRequestBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _username = $v.username;
      _password = $v.password;
      _displayName = $v.displayName;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(SetupRequest other) {
    _$v = other as _$SetupRequest;
  }

  @override
  void update(void Function(SetupRequestBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  SetupRequest build() => _build();

  _$SetupRequest _build() {
    final _$result = _$v ??
        _$SetupRequest._(
          username: BuiltValueNullFieldError.checkNotNull(
              username, r'SetupRequest', 'username'),
          password: BuiltValueNullFieldError.checkNotNull(
              password, r'SetupRequest', 'password'),
          displayName: displayName,
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
