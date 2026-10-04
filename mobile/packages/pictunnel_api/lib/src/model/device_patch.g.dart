// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_patch.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$DevicePatch extends DevicePatch {
  @override
  final String name;

  factory _$DevicePatch([void Function(DevicePatchBuilder)? updates]) =>
      (DevicePatchBuilder()..update(updates))._build();

  _$DevicePatch._({required this.name}) : super._();
  @override
  DevicePatch rebuild(void Function(DevicePatchBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  DevicePatchBuilder toBuilder() => DevicePatchBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is DevicePatch && name == other.name;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, name.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'DevicePatch')..add('name', name))
        .toString();
  }
}

class DevicePatchBuilder implements Builder<DevicePatch, DevicePatchBuilder> {
  _$DevicePatch? _$v;

  String? _name;
  String? get name => _$this._name;
  set name(String? name) => _$this._name = name;

  DevicePatchBuilder() {
    DevicePatch._defaults(this);
  }

  DevicePatchBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _name = $v.name;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(DevicePatch other) {
    _$v = other as _$DevicePatch;
  }

  @override
  void update(void Function(DevicePatchBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  DevicePatch build() => _build();

  _$DevicePatch _build() {
    final _$result = _$v ??
        _$DevicePatch._(
          name: BuiltValueNullFieldError.checkNotNull(
              name, r'DevicePatch', 'name'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
