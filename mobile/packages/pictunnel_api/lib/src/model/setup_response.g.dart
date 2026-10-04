// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'setup_response.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$SetupResponse extends SetupResponse {
  @override
  final User user;

  factory _$SetupResponse([void Function(SetupResponseBuilder)? updates]) =>
      (SetupResponseBuilder()..update(updates))._build();

  _$SetupResponse._({required this.user}) : super._();
  @override
  SetupResponse rebuild(void Function(SetupResponseBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  SetupResponseBuilder toBuilder() => SetupResponseBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is SetupResponse && user == other.user;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, user.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'SetupResponse')..add('user', user))
        .toString();
  }
}

class SetupResponseBuilder
    implements Builder<SetupResponse, SetupResponseBuilder> {
  _$SetupResponse? _$v;

  UserBuilder? _user;
  UserBuilder get user => _$this._user ??= UserBuilder();
  set user(UserBuilder? user) => _$this._user = user;

  SetupResponseBuilder() {
    SetupResponse._defaults(this);
  }

  SetupResponseBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _user = $v.user.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(SetupResponse other) {
    _$v = other as _$SetupResponse;
  }

  @override
  void update(void Function(SetupResponseBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  SetupResponse build() => _build();

  _$SetupResponse _build() {
    _$SetupResponse _$result;
    try {
      _$result = _$v ??
          _$SetupResponse._(
            user: user.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'user';
        user.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'SetupResponse', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
