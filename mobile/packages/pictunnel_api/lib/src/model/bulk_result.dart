//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_collection/built_collection.dart';
import 'package:pictunnel_api/src/model/bulk_failure.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'bulk_result.g.dart';

/// BulkResult
///
/// Properties:
/// * [succeeded] 
/// * [failed] 
@BuiltValue()
abstract class BulkResult implements Built<BulkResult, BulkResultBuilder> {
  @BuiltValueField(wireName: r'succeeded')
  BuiltList<String> get succeeded;

  @BuiltValueField(wireName: r'failed')
  BuiltList<BulkFailure> get failed;

  BulkResult._();

  factory BulkResult([void updates(BulkResultBuilder b)]) = _$BulkResult;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(BulkResultBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<BulkResult> get serializer => _$BulkResultSerializer();
}

class _$BulkResultSerializer implements PrimitiveSerializer<BulkResult> {
  @override
  final Iterable<Type> types = const [BulkResult, _$BulkResult];

  @override
  final String wireName = r'BulkResult';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    BulkResult object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'succeeded';
    yield serializers.serialize(
      object.succeeded,
      specifiedType: const FullType(BuiltList, [FullType(String)]),
    );
    yield r'failed';
    yield serializers.serialize(
      object.failed,
      specifiedType: const FullType(BuiltList, [FullType(BulkFailure)]),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    BulkResult object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required BulkResultBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'succeeded':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(BuiltList, [FullType(String)]),
          ) as BuiltList<String>;
          result.succeeded.replace(valueDes);
          break;
        case r'failed':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(BuiltList, [FullType(BulkFailure)]),
          ) as BuiltList<BulkFailure>;
          result.failed.replace(valueDes);
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  BulkResult deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = BulkResultBuilder();
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

