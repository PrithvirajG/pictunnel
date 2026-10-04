//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'empty_trash_result.g.dart';

/// EmptyTrashResult
///
/// Properties:
/// * [purgedCount] 
@BuiltValue()
abstract class EmptyTrashResult implements Built<EmptyTrashResult, EmptyTrashResultBuilder> {
  @BuiltValueField(wireName: r'purged_count')
  int get purgedCount;

  EmptyTrashResult._();

  factory EmptyTrashResult([void updates(EmptyTrashResultBuilder b)]) = _$EmptyTrashResult;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(EmptyTrashResultBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<EmptyTrashResult> get serializer => _$EmptyTrashResultSerializer();
}

class _$EmptyTrashResultSerializer implements PrimitiveSerializer<EmptyTrashResult> {
  @override
  final Iterable<Type> types = const [EmptyTrashResult, _$EmptyTrashResult];

  @override
  final String wireName = r'EmptyTrashResult';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    EmptyTrashResult object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'purged_count';
    yield serializers.serialize(
      object.purgedCount,
      specifiedType: const FullType(int),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    EmptyTrashResult object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required EmptyTrashResultBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'purged_count':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(int),
          ) as int;
          result.purgedCount = valueDes;
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  EmptyTrashResult deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = EmptyTrashResultBuilder();
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

