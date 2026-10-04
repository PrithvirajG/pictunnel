// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'upload_ref.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$UploadRef extends UploadRef {
  @override
  final String id;
  @override
  final String url;
  @override
  final int offset;
  @override
  final int length;
  @override
  final DateTime expiresAt;

  factory _$UploadRef([void Function(UploadRefBuilder)? updates]) =>
      (UploadRefBuilder()..update(updates))._build();

  _$UploadRef._(
      {required this.id,
      required this.url,
      required this.offset,
      required this.length,
      required this.expiresAt})
      : super._();
  @override
  UploadRef rebuild(void Function(UploadRefBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  UploadRefBuilder toBuilder() => UploadRefBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is UploadRef &&
        id == other.id &&
        url == other.url &&
        offset == other.offset &&
        length == other.length &&
        expiresAt == other.expiresAt;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, id.hashCode);
    _$hash = $jc(_$hash, url.hashCode);
    _$hash = $jc(_$hash, offset.hashCode);
    _$hash = $jc(_$hash, length.hashCode);
    _$hash = $jc(_$hash, expiresAt.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'UploadRef')
          ..add('id', id)
          ..add('url', url)
          ..add('offset', offset)
          ..add('length', length)
          ..add('expiresAt', expiresAt))
        .toString();
  }
}

class UploadRefBuilder implements Builder<UploadRef, UploadRefBuilder> {
  _$UploadRef? _$v;

  String? _id;
  String? get id => _$this._id;
  set id(String? id) => _$this._id = id;

  String? _url;
  String? get url => _$this._url;
  set url(String? url) => _$this._url = url;

  int? _offset;
  int? get offset => _$this._offset;
  set offset(int? offset) => _$this._offset = offset;

  int? _length;
  int? get length => _$this._length;
  set length(int? length) => _$this._length = length;

  DateTime? _expiresAt;
  DateTime? get expiresAt => _$this._expiresAt;
  set expiresAt(DateTime? expiresAt) => _$this._expiresAt = expiresAt;

  UploadRefBuilder() {
    UploadRef._defaults(this);
  }

  UploadRefBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _id = $v.id;
      _url = $v.url;
      _offset = $v.offset;
      _length = $v.length;
      _expiresAt = $v.expiresAt;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(UploadRef other) {
    _$v = other as _$UploadRef;
  }

  @override
  void update(void Function(UploadRefBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  UploadRef build() => _build();

  _$UploadRef _build() {
    final _$result = _$v ??
        _$UploadRef._(
          id: BuiltValueNullFieldError.checkNotNull(id, r'UploadRef', 'id'),
          url: BuiltValueNullFieldError.checkNotNull(url, r'UploadRef', 'url'),
          offset: BuiltValueNullFieldError.checkNotNull(
              offset, r'UploadRef', 'offset'),
          length: BuiltValueNullFieldError.checkNotNull(
              length, r'UploadRef', 'length'),
          expiresAt: BuiltValueNullFieldError.checkNotNull(
              expiresAt, r'UploadRef', 'expiresAt'),
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
