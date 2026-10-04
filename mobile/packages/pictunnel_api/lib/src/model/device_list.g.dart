// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_list.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$DeviceList extends DeviceList {
  @override
  final BuiltList<Device> devices;

  factory _$DeviceList([void Function(DeviceListBuilder)? updates]) =>
      (DeviceListBuilder()..update(updates))._build();

  _$DeviceList._({required this.devices}) : super._();
  @override
  DeviceList rebuild(void Function(DeviceListBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  DeviceListBuilder toBuilder() => DeviceListBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is DeviceList && devices == other.devices;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, devices.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'DeviceList')..add('devices', devices))
        .toString();
  }
}

class DeviceListBuilder implements Builder<DeviceList, DeviceListBuilder> {
  _$DeviceList? _$v;

  ListBuilder<Device>? _devices;
  ListBuilder<Device> get devices => _$this._devices ??= ListBuilder<Device>();
  set devices(ListBuilder<Device>? devices) => _$this._devices = devices;

  DeviceListBuilder() {
    DeviceList._defaults(this);
  }

  DeviceListBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _devices = $v.devices.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(DeviceList other) {
    _$v = other as _$DeviceList;
  }

  @override
  void update(void Function(DeviceListBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  DeviceList build() => _build();

  _$DeviceList _build() {
    _$DeviceList _$result;
    try {
      _$result = _$v ??
          _$DeviceList._(
            devices: devices.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'devices';
        devices.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'DeviceList', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
