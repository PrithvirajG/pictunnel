// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bulk_result.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$BulkResult extends BulkResult {
  @override
  final BuiltList<String> succeeded;
  @override
  final BuiltList<BulkFailure> failed;

  factory _$BulkResult([void Function(BulkResultBuilder)? updates]) =>
      (BulkResultBuilder()..update(updates))._build();

  _$BulkResult._({required this.succeeded, required this.failed}) : super._();
  @override
  BulkResult rebuild(void Function(BulkResultBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  BulkResultBuilder toBuilder() => BulkResultBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is BulkResult &&
        succeeded == other.succeeded &&
        failed == other.failed;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, succeeded.hashCode);
    _$hash = $jc(_$hash, failed.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'BulkResult')
          ..add('succeeded', succeeded)
          ..add('failed', failed))
        .toString();
  }
}

class BulkResultBuilder implements Builder<BulkResult, BulkResultBuilder> {
  _$BulkResult? _$v;

  ListBuilder<String>? _succeeded;
  ListBuilder<String> get succeeded =>
      _$this._succeeded ??= ListBuilder<String>();
  set succeeded(ListBuilder<String>? succeeded) =>
      _$this._succeeded = succeeded;

  ListBuilder<BulkFailure>? _failed;
  ListBuilder<BulkFailure> get failed =>
      _$this._failed ??= ListBuilder<BulkFailure>();
  set failed(ListBuilder<BulkFailure>? failed) => _$this._failed = failed;

  BulkResultBuilder() {
    BulkResult._defaults(this);
  }

  BulkResultBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _succeeded = $v.succeeded.toBuilder();
      _failed = $v.failed.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(BulkResult other) {
    _$v = other as _$BulkResult;
  }

  @override
  void update(void Function(BulkResultBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  BulkResult build() => _build();

  _$BulkResult _build() {
    _$BulkResult _$result;
    try {
      _$result = _$v ??
          _$BulkResult._(
            succeeded: succeeded.build(),
            failed: failed.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'succeeded';
        succeeded.build();
        _$failedField = 'failed';
        failed.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'BulkResult', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
