//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'device_patch.g.dart';

/// DevicePatch
///
/// Properties:
/// * [name] 
@BuiltValue()
abstract class DevicePatch implements Built<DevicePatch, DevicePatchBuilder> {
  @BuiltValueField(wireName: r'name')
  String get name;

  DevicePatch._();

  factory DevicePatch([void updates(DevicePatchBuilder b)]) = _$DevicePatch;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(DevicePatchBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<DevicePatch> get serializer => _$DevicePatchSerializer();
}

class _$DevicePatchSerializer implements PrimitiveSerializer<DevicePatch> {
  @override
  final Iterable<Type> types = const [DevicePatch, _$DevicePatch];

  @override
  final String wireName = r'DevicePatch';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    DevicePatch object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'name';
    yield serializers.serialize(
      object.name,
      specifiedType: const FullType(String),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    DevicePatch object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required DevicePatchBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'name':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.name = valueDes;
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  DevicePatch deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = DevicePatchBuilder();
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

