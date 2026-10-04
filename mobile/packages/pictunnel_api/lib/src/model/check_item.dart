//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'check_item.g.dart';

/// CheckItem
///
/// Properties:
/// * [sha256] - Lowercase hex SHA-256 of the original bytes.
/// * [sizeBytes] 
/// * [localId] - Device-local identifier; linked to the asset when the verdict is `exists`.
/// * [confirmOnDisk] - Ask the server to stat the original and report `on_disk` (used before freeing space).
@BuiltValue()
abstract class CheckItem implements Built<CheckItem, CheckItemBuilder> {
  /// Lowercase hex SHA-256 of the original bytes.
  @BuiltValueField(wireName: r'sha256')
  String get sha256;

  @BuiltValueField(wireName: r'size_bytes')
  int get sizeBytes;

  /// Device-local identifier; linked to the asset when the verdict is `exists`.
  @BuiltValueField(wireName: r'local_id')
  String? get localId;

  /// Ask the server to stat the original and report `on_disk` (used before freeing space).
  @BuiltValueField(wireName: r'confirm_on_disk')
  bool? get confirmOnDisk;

  CheckItem._();

  factory CheckItem([void updates(CheckItemBuilder b)]) = _$CheckItem;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(CheckItemBuilder b) => b
      ..confirmOnDisk = false;

  @BuiltValueSerializer(custom: true)
  static Serializer<CheckItem> get serializer => _$CheckItemSerializer();
}

class _$CheckItemSerializer implements PrimitiveSerializer<CheckItem> {
  @override
  final Iterable<Type> types = const [CheckItem, _$CheckItem];

  @override
  final String wireName = r'CheckItem';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    CheckItem object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'sha256';
    yield serializers.serialize(
      object.sha256,
      specifiedType: const FullType(String),
    );
    yield r'size_bytes';
    yield serializers.serialize(
      object.sizeBytes,
      specifiedType: const FullType(int),
    );
    if (object.localId != null) {
      yield r'local_id';
      yield serializers.serialize(
        object.localId,
        specifiedType: const FullType(String),
      );
    }
    if (object.confirmOnDisk != null) {
      yield r'confirm_on_disk';
      yield serializers.serialize(
        object.confirmOnDisk,
        specifiedType: const FullType(bool),
      );
    }
  }

  @override
  Object serialize(
    Serializers serializers,
    CheckItem object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required CheckItemBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'sha256':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.sha256 = valueDes;
          break;
        case r'size_bytes':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(int),
          ) as int;
          result.sizeBytes = valueDes;
          break;
        case r'local_id':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(String),
          ) as String?;
          if (valueDes == null) continue;
          result.localId = valueDes;
          break;
        case r'confirm_on_disk':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(bool),
          ) as bool?;
          if (valueDes == null) continue;
          result.confirmOnDisk = valueDes;
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  CheckItem deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = CheckItemBuilder();
    final serializedList = (serialized as Iterable<Object?>).toList();
    final unhandled = <Object?>[];
    _deserializeProperties(
      serializers,
      serialized,
      specifiedType: specifiedType,
      serializedList: serializedList,
      unhandled: unhandled,
      result: result,
    );
    return result.build();
  }
}

