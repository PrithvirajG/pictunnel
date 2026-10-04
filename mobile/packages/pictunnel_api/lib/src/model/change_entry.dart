//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:pictunnel_api/src/model/asset.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'change_entry.g.dart';

/// ChangeEntry
///
/// Properties:
/// * [seq] 
/// * [kind] 
/// * [asset] 
/// * [assetId] - Present for `asset.removed`.
@BuiltValue()
abstract class ChangeEntry implements Built<ChangeEntry, ChangeEntryBuilder> {
  @BuiltValueField(wireName: r'seq')
  int get seq;

  @BuiltValueField(wireName: r'kind')
  String get kind;

  @BuiltValueField(wireName: r'asset')
  Asset? get asset;

  /// Present for `asset.removed`.
  @BuiltValueField(wireName: r'asset_id')
  String? get assetId;

  ChangeEntry._();

  factory ChangeEntry([void updates(ChangeEntryBuilder b)]) = _$ChangeEntry;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(ChangeEntryBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<ChangeEntry> get serializer => _$ChangeEntrySerializer();
}

class _$ChangeEntrySerializer implements PrimitiveSerializer<ChangeEntry> {
  @override
  final Iterable<Type> types = const [ChangeEntry, _$ChangeEntry];

  @override
  final String wireName = r'ChangeEntry';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    ChangeEntry object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'seq';
    yield serializers.serialize(
      object.seq,
      specifiedType: const FullType(int),
    );
    yield r'kind';
    yield serializers.serialize(
      object.kind,
      specifiedType: const FullType(String),
    );
    if (object.asset != null) {
      yield r'asset';
      yield serializers.serialize(
        object.asset,
        specifiedType: const FullType(Asset),
      );
    }
    if (object.assetId != null) {
      yield r'asset_id';
      yield serializers.serialize(
        object.assetId,
        specifiedType: const FullType(String),
      );
    }
  }

  @override
  Object serialize(
    Serializers serializers,
    ChangeEntry object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required ChangeEntryBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'seq':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(int),
          ) as int;
          result.seq = valueDes;
          break;
        case r'kind':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.kind = valueDes;
          break;
        case r'asset':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(Asset),
          ) as Asset?;
          if (valueDes == null) continue;
          result.asset.replace(valueDes);
          break;
        case r'asset_id':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(String),
          ) as String?;
          if (valueDes == null) continue;
          result.assetId = valueDes;
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  ChangeEntry deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = ChangeEntryBuilder();
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

