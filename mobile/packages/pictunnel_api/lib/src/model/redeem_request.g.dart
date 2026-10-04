// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'redeem_request.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$RedeemRequest extends RedeemRequest {
  @override
  final String code;
  @override
  final DeviceRegistration device;

  factory _$RedeemRequest([void Function(RedeemRequestBuilder)? updates]) =>
      (RedeemRequestBuilder()..update(updates))._build();

  _$RedeemRequest._({required this.code, required this.device}) : super._();
  @override
  RedeemRequest rebuild(void Function(RedeemRequestBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  RedeemRequestBuilder toBuilder() => RedeemRequestBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is RedeemRequest &&
        code == other.code &&
        device == other.device;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, code.hashCode);
    _$hash = $jc(_$hash, device.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'RedeemRequest')
          ..add('code', code)
          ..add('device', device))
        .toString();
  }
}

class RedeemRequestBuilder
    implements Builder<RedeemRequest, RedeemRequestBuilder> {
  _$RedeemRequest? _$v;

  String? _code;
  String? get code => _$this._code;
  set code(String? code) => _$this._code = code;

  DeviceRegistrationBuilder? _device;
  DeviceRegistrationBuilder get device =>
      _$this._device ??= DeviceRegistrationBuilder();
  set device(DeviceRegistrationBuilder? device) => _$this._device = device;

  RedeemRequestBuilder() {
    RedeemRequest._defaults(this);
  }

  RedeemRequestBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _code = $v.code;
      _device = $v.device.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(RedeemRequest other) {
    _$v = other as _$RedeemRequest;
  }

  @override
  void update(void Function(RedeemRequestBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  RedeemRequest build() => _build();

  _$RedeemRequest _build() {
    _$RedeemRequest _$result;
    try {
      _$result = _$v ??
          _$RedeemRequest._(
            code: BuiltValueNullFieldError.checkNotNull(
                code, r'RedeemRequest', 'code'),
            device: device.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'device';
        device.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'RedeemRequest', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
