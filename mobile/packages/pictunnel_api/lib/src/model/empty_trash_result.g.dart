// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'empty_trash_result.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$EmptyTrashResult extends EmptyTrashResult {
  @override
  final int purgedCount;

  factory _$EmptyTrashResult(
          [void Function(EmptyTrashResultBuilder)? updates]) =>
      (EmptyTrashResultBuilder()..update(updates))._build();

  _$EmptyTrashResult._({required this.purgedCount}) : super._();
  @override
  EmptyTrashResult rebuild(void Function(EmptyTrashResultBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  EmptyTrashResultBuilder toBuilder() =>
      EmptyTrashResultBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is EmptyTrashResult && purgedCount == other.purgedCount;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, purgedCount.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'EmptyTrashResult')
          ..add('purgedCount', purgedCount))
        .toString();
  }
}

class EmptyTrashResultBuilder
    implements Builder<EmptyTrashResult, EmptyTrashResultBuilder> {
  _$EmptyTrashResult? _$v;

  int? _purgedCount;
  int? get purgedCount => _$this._purgedCount;
  set purgedCount(int? purgedCount) => _$this._purgedCount = purgedCount;

  EmptyTrashResultBuilder() {
    EmptyTrashResult._defaults(this);
  }

  EmptyTrashResultBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _purgedCount = $v.purgedCount;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(EmptyTrashResult other) {
    _$v = other as _$EmptyTrashResult;
  }

  @override
  void update(void Function(EmptyTrashResultBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  EmptyTrashResult build() => _build();

  _$EmptyTrashResult _build() {
    final _$result = _$v ??
        _$EmptyTrashResult._(
          purgedCount: BuiltValueNullFieldError.checkNotNull(
              purgedCount, r'EmptyTrashResult', 'purgedCount'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
