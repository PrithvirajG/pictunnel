//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'upload_limits.g.dart';

/// UploadLimits
///
/// Properties:
/// * [tusVersion] 
/// * [maxFileBytes] 
/// * [recommendedChunkBytes] 
@BuiltValue()
abstract class UploadLimits implements Built<UploadLimits, UploadLimitsBuilder> {
  @BuiltValueField(wireName: r'tus_version')
  String get tusVersion;

  @BuiltValueField(wireName: r'max_file_bytes')
  int get maxFileBytes;

  @BuiltValueField(wireName: r'recommended_chunk_bytes')
  int get recommendedChunkBytes;

  UploadLimits._();

  factory UploadLimits([void updates(UploadLimitsBuilder b)]) = _$UploadLimits;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(UploadLimitsBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<UploadLimits> get serializer => _$UploadLimitsSerializer();
}

class _$UploadLimitsSerializer implements PrimitiveSerializer<UploadLimits> {
  @override
  final Iterable<Type> types = const [UploadLimits, _$UploadLimits];

  @override
  final String wireName = r'UploadLimits';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    UploadLimits object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'tus_version';
    yield serializers.serialize(
      object.tusVersion,
      specifiedType: const FullType(String),
    );
    yield r'max_file_bytes';
    yield serializers.serialize(
      object.maxFileBytes,
      specifiedType: const FullType(int),
    );
    yield r'recommended_chunk_bytes';
    yield serializers.serialize(
      object.recommendedChunkBytes,
      specifiedType: const FullType(int),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    UploadLimits object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required UploadLimitsBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'tus_version':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.tusVersion = valueDes;
          break;
        case r'max_file_bytes':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(int),
          ) as int;
          result.maxFileBytes = valueDes;
          break;
        case r'recommended_chunk_bytes':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(int),
          ) as int;
          result.recommendedChunkBytes = valueDes;
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  UploadLimits deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = UploadLimitsBuilder();
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

