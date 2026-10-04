// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'check_request.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$CheckRequest extends CheckRequest {
  @override
  final BuiltList<CheckItem> items;

  factory _$CheckRequest([void Function(CheckRequestBuilder)? updates]) =>
      (CheckRequestBuilder()..update(updates))._build();

  _$CheckRequest._({required this.items}) : super._();
  @override
  CheckRequest rebuild(void Function(CheckRequestBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  CheckRequestBuilder toBuilder() => CheckRequestBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is CheckRequest && items == other.items;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, items.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'CheckRequest')..add('items', items))
        .toString();
  }
}

class CheckRequestBuilder
    implements Builder<CheckRequest, CheckRequestBuilder> {
  _$CheckRequest? _$v;

  ListBuilder<CheckItem>? _items;
  ListBuilder<CheckItem> get items =>
      _$this._items ??= ListBuilder<CheckItem>();
  set items(ListBuilder<CheckItem>? items) => _$this._items = items;

  CheckRequestBuilder() {
    CheckRequest._defaults(this);
  }

  CheckRequestBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _items = $v.items.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(CheckRequest other) {
    _$v = other as _$CheckRequest;
  }

  @override
  void update(void Function(CheckRequestBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  CheckRequest build() => _build();

  _$CheckRequest _build() {
    _$CheckRequest _$result;
    try {
      _$result = _$v ??
          _$CheckRequest._(
            items: items.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'items';
        items.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'CheckRequest', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
