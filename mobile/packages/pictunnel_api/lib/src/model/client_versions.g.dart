// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'client_versions.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$ClientVersions extends ClientVersions {
  @override
  final String android;
  @override
  final String ios;
  @override
  final String web;

  factory _$ClientVersions([void Function(ClientVersionsBuilder)? updates]) =>
      (ClientVersionsBuilder()..update(updates))._build();

  _$ClientVersions._(
      {required this.android, required this.ios, required this.web})
      : super._();
  @override
  ClientVersions rebuild(void Function(ClientVersionsBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  ClientVersionsBuilder toBuilder() => ClientVersionsBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is ClientVersions &&
        android == other.android &&
        ios == other.ios &&
        web == other.web;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, android.hashCode);
    _$hash = $jc(_$hash, ios.hashCode);
    _$hash = $jc(_$hash, web.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'ClientVersions')
          ..add('android', android)
          ..add('ios', ios)
          ..add('web', web))
        .toString();
  }
}

class ClientVersionsBuilder
    implements Builder<ClientVersions, ClientVersionsBuilder> {
  _$ClientVersions? _$v;

  String? _android;
  String? get android => _$this._android;
  set android(String? android) => _$this._android = android;

  String? _ios;
  String? get ios => _$this._ios;
  set ios(String? ios) => _$this._ios = ios;

  String? _web;
  String? get web => _$this._web;
  set web(String? web) => _$this._web = web;

  ClientVersionsBuilder() {
    ClientVersions._defaults(this);
  }

  ClientVersionsBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _android = $v.android;
      _ios = $v.ios;
      _web = $v.web;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(ClientVersions other) {
    _$v = other as _$ClientVersions;
  }

  @override
  void update(void Function(ClientVersionsBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  ClientVersions build() => _build();

  _$ClientVersions _build() {
    final _$result = _$v ??
        _$ClientVersions._(
          android: BuiltValueNullFieldError.checkNotNull(
              android, r'ClientVersions', 'android'),
          ios: BuiltValueNullFieldError.checkNotNull(
              ios, r'ClientVersions', 'ios'),
          web: BuiltValueNullFieldError.checkNotNull(
              web, r'ClientVersions', 'web'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
