// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'check_response.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$CheckResponse extends CheckResponse {
  @override
  final BuiltList<CheckResult> results;

  factory _$CheckResponse([void Function(CheckResponseBuilder)? updates]) =>
      (CheckResponseBuilder()..update(updates))._build();

  _$CheckResponse._({required this.results}) : super._();
  @override
  CheckResponse rebuild(void Function(CheckResponseBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  CheckResponseBuilder toBuilder() => CheckResponseBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is CheckResponse && results == other.results;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, results.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'CheckResponse')
          ..add('results', results))
        .toString();
  }
}

class CheckResponseBuilder
    implements Builder<CheckResponse, CheckResponseBuilder> {
  _$CheckResponse? _$v;

  ListBuilder<CheckResult>? _results;
  ListBuilder<CheckResult> get results =>
      _$this._results ??= ListBuilder<CheckResult>();
  set results(ListBuilder<CheckResult>? results) => _$this._results = results;

  CheckResponseBuilder() {
    CheckResponse._defaults(this);
  }

  CheckResponseBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _results = $v.results.toBuilder();
      _$v = null;
    }
    return this;
  }

  @override
  void replace(CheckResponse other) {
    _$v = other as _$CheckResponse;
  }

  @override
  void update(void Function(CheckResponseBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  CheckResponse build() => _build();

  _$CheckResponse _build() {
    _$CheckResponse _$result;
    try {
      _$result = _$v ??
          _$CheckResponse._(
            results: results.build(),
          );
    } catch (_) {
      late String _$failedField;
      try {
        _$failedField = 'results';
        results.build();
      } catch (e) {
        throw BuiltValueNestedFieldError(
            r'CheckResponse', _$failedField, e.toString());
      }
      rethrow;
    }
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
