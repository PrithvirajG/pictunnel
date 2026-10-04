//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:pictunnel_api/src/model/upload_ref.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'check_result.g.dart';

/// CheckResult
///
/// Properties:
/// * [sha256] - Lowercase hex SHA-256 of the original bytes.
/// * [verdict] 
/// * [assetId] 
/// * [assetState] 
/// * [hasLiveVideo] 
/// * [onDisk] 
/// * [upload] 
/// * [deletedAt] 
@BuiltValue()
abstract class CheckResult implements Built<CheckResult, CheckResultBuilder> {
  /// Lowercase hex SHA-256 of the original bytes.
  @BuiltValueField(wireName: r'sha256')
  String get sha256;

  @BuiltValueField(wireName: r'verdict')
  String get verdict;

  @BuiltValueField(wireName: r'asset_id')
  String? get assetId;

  @BuiltValueField(wireName: r'asset_state')
  String? get assetState;

  @BuiltValueField(wireName: r'has_live_video')
  bool? get hasLiveVideo;

  @BuiltValueField(wireName: r'on_disk')
  bool? get onDisk;

  @BuiltValueField(wireName: r'upload')
  UploadRef? get upload;

  @BuiltValueField(wireName: r'deleted_at')
  DateTime? get deletedAt;

  CheckResult._();

  factory CheckResult([void updates(CheckResultBuilder b)]) = _$CheckResult;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(CheckResultBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<CheckResult> get serializer => _$CheckResultSerializer();
}

class _$CheckResultSerializer implements PrimitiveSerializer<CheckResult> {
  @override
  final Iterable<Type> types = const [CheckResult, _$CheckResult];

  @override
  final String wireName = r'CheckResult';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    CheckResult object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'sha256';
    yield serializers.serialize(
      object.sha256,
      specifiedType: const FullType(String),
    );
    yield r'verdict';
    yield serializers.serialize(
      object.verdict,
      specifiedType: const FullType(String),
    );
    if (object.assetId != null) {
      yield r'asset_id';
      yield serializers.serialize(
        object.assetId,
        specifiedType: const FullType(String),
      );
    }
    if (object.assetState != null) {
      yield r'asset_state';
      yield serializers.serialize(
        object.assetState,
        specifiedType: const FullType(String),
      );
    }
    if (object.hasLiveVideo != null) {
      yield r'has_live_video';
      yield serializers.serialize(
        object.hasLiveVideo,
        specifiedType: const FullType(bool),
      );
    }
    if (object.onDisk != null) {
      yield r'on_disk';
      yield serializers.serialize(
        object.onDisk,
        specifiedType: const FullType(bool),
      );
    }
    if (object.upload != null) {
      yield r'upload';
      yield serializers.serialize(
        object.upload,
        specifiedType: const FullType(UploadRef),
      );
    }
    if (object.deletedAt != null) {
      yield r'deleted_at';
      yield serializers.serialize(
        object.deletedAt,
        specifiedType: const FullType(DateTime),
      );
    }
  }

  @override
  Object serialize(
    Serializers serializers,
    CheckResult object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required CheckResultBuilder result,
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
        case r'verdict':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.verdict = valueDes;
          break;
        case r'asset_id':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(String),
          ) as String?;
          if (valueDes == null) continue;
          result.assetId = valueDes;
          break;
        case r'asset_state':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(String),
          ) as String?;
          if (valueDes == null) continue;
          result.assetState = valueDes;
          break;
        case r'has_live_video':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(bool),
          ) as bool?;
          if (valueDes == null) continue;
          result.hasLiveVideo = valueDes;
          break;
        case r'on_disk':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(bool),
          ) as bool?;
          if (valueDes == null) continue;
          result.onDisk = valueDes;
          break;
        case r'upload':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(UploadRef),
          ) as UploadRef?;
          if (valueDes == null) continue;
          result.upload.replace(valueDes);
          break;
        case r'deleted_at':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(DateTime),
          ) as DateTime?;
          if (valueDes == null) continue;
          result.deletedAt = valueDes;
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  CheckResult deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = CheckResultBuilder();
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

