// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'token_pair.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$TokenPair extends TokenPair {
  @override
  final String accessToken;
  @override
  final DateTime accessTokenExpiresAt;
  @override
  final String refreshToken;
  @override
  final DateTime refreshTokenExpiresAt;

  factory _$TokenPair([void Function(TokenPairBuilder)? updates]) =>
      (TokenPairBuilder()..update(updates))._build();

  _$TokenPair._(
      {required this.accessToken,
      required this.accessTokenExpiresAt,
      required this.refreshToken,
      required this.refreshTokenExpiresAt})
      : super._();
  @override
  TokenPair rebuild(void Function(TokenPairBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  TokenPairBuilder toBuilder() => TokenPairBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is TokenPair &&
        accessToken == other.accessToken &&
        accessTokenExpiresAt == other.accessTokenExpiresAt &&
        refreshToken == other.refreshToken &&
        refreshTokenExpiresAt == other.refreshTokenExpiresAt;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, accessToken.hashCode);
    _$hash = $jc(_$hash, accessTokenExpiresAt.hashCode);
    _$hash = $jc(_$hash, refreshToken.hashCode);
    _$hash = $jc(_$hash, refreshTokenExpiresAt.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'TokenPair')
          ..add('accessToken', accessToken)
          ..add('accessTokenExpiresAt', accessTokenExpiresAt)
          ..add('refreshToken', refreshToken)
          ..add('refreshTokenExpiresAt', refreshTokenExpiresAt))
        .toString();
  }
}

class TokenPairBuilder implements Builder<TokenPair, TokenPairBuilder> {
  _$TokenPair? _$v;

  String? _accessToken;
  String? get accessToken => _$this._accessToken;
  set accessToken(String? accessToken) => _$this._accessToken = accessToken;

  DateTime? _accessTokenExpiresAt;
  DateTime? get accessTokenExpiresAt => _$this._accessTokenExpiresAt;
  set accessTokenExpiresAt(DateTime? accessTokenExpiresAt) =>
      _$this._accessTokenExpiresAt = accessTokenExpiresAt;

  String? _refreshToken;
  String? get refreshToken => _$this._refreshToken;
  set refreshToken(String? refreshToken) => _$this._refreshToken = refreshToken;

  DateTime? _refreshTokenExpiresAt;
  DateTime? get refreshTokenExpiresAt => _$this._refreshTokenExpiresAt;
  set refreshTokenExpiresAt(DateTime? refreshTokenExpiresAt) =>
      _$this._refreshTokenExpiresAt = refreshTokenExpiresAt;

  TokenPairBuilder() {
    TokenPair._defaults(this);
  }

  TokenPairBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _accessToken = $v.accessToken;
      _accessTokenExpiresAt = $v.accessTokenExpiresAt;
      _refreshToken = $v.refreshToken;
      _refreshTokenExpiresAt = $v.refreshTokenExpiresAt;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(TokenPair other) {
    _$v = other as _$TokenPair;
  }

  @override
  void update(void Function(TokenPairBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  TokenPair build() => _build();

  _$TokenPair _build() {
    final _$result = _$v ??
        _$TokenPair._(
          accessToken: BuiltValueNullFieldError.checkNotNull(
              accessToken, r'TokenPair', 'accessToken'),
          accessTokenExpiresAt: BuiltValueNullFieldError.checkNotNull(
              accessTokenExpiresAt, r'TokenPair', 'accessTokenExpiresAt'),
          refreshToken: BuiltValueNullFieldError.checkNotNull(
              refreshToken, r'TokenPair', 'refreshToken'),
          refreshTokenExpiresAt: BuiltValueNullFieldError.checkNotNull(
              refreshTokenExpiresAt, r'TokenPair', 'refreshTokenExpiresAt'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
