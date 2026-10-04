// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'redeem_response.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$RedeemResponse extends RedeemResponse {
  @override
  final String serverId;
  @override
  final User user;
  @override
  final Device device;
  @override
  final TokenPair tokens;

  factory _$RedeemResponse([void Function(RedeemResponseBuilder)? updates]) =>
      (RedeemResponseBuilder()..update(updates))._build();

  _$RedeemResponse._(
      {required this.serverId,
      required this.user,
      required this.device,
      required this.tokens})
      : super._();
  @override
  RedeemResponse rebuild(void Function(RedeemResponseBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  RedeemResponseBuilder toBuilder() => RedeemResponseBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is RedeemResponse &&
        serverId == other.serverId &&
        user == other.user &&
        device == other.device &&
        tokens == other.tokens;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, serverId.hashCode);
    _$hash = $jc(_$hash, user.hashCode);
    _$hash = $jc(_$hash, device.hashCode);
    _$hash = $jc(_$hash, tokens.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'RedeemResponse')
          ..add('serverId', serverId)
          ..add('user', user)
          ..add('device', device)
          ..add('tokens', tokens))
        .toString();
  }
}

class RedeemResponseBuilder
    implements Builder<RedeemResponse, RedeemResponseBuilder> {
  _$RedeemResponse? _$v;

  String? _serverId;
  String? get serverId => _$this._serverId;
  set serverId(String? serverId) => _$this._serverId = serverId;

  UserBuilder? _user;
  UserBuilder get user => _$this._user ??= UserBuilder();
  set user(UserBuilder? user) => _$this._user = user;

  DeviceBuilder? _device;
  DeviceBuilder get device => _$this._device ??= DeviceBuilder();
  set device(DeviceBuilder? device) => _$this._device = device;

  TokenPairBuilder? _tokens;
  TokenPairBuilder get tokens => _$this._tokens ??= TokenPairBuilder();
  set tokens(TokenPairBuilder? tokens) => _$this._tokens = tokens;

  RedeemResponseBuilder() {
    RedeemResponse._defaults(this);
  }

  RedeemResponseBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _serverId = $v.serverId;
      _user = $v.user.toBuilder();
      _device = $v.device.toBuilder();
      _tokens = $v.tokens.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(RedeemResponse other) {
    _$v = other as _$RedeemResponse;
  }

  @override
  void update(void Function(RedeemResponseBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  RedeemResponse build() => _build();

  _$RedeemResponse _build() {
    _$RedeemResponse _$result;
    try {
      _$result = _$v ??
          _$RedeemResponse._(
            serverId: BuiltValueNullFieldError.checkNotNull(
                serverId, r'RedeemResponse', 'serverId'),
            user: user.build(),
            device: device.build(),
            tokens: tokens.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'user';
        user.build();
        _$failedField = 'device';
        device.build();
        _$failedField = 'tokens';
        tokens.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'RedeemResponse', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
