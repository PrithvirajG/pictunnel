//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'asset_id_list.g.dart';

/// AssetIdList
///
/// Properties:
/// * [assetIds] 
@BuiltValue()
abstract class AssetIdList implements Built<AssetIdList, AssetIdListBuilder> {
  @BuiltValueField(wireName: r'asset_ids')
  BuiltList<String> get assetIds;

  AssetIdList._();

  factory AssetIdList([void updates(AssetIdListBuilder b)]) = _$AssetIdList;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(AssetIdListBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<AssetIdList> get serializer => _$AssetIdListSerializer();
}

class _$AssetIdListSerializer implements PrimitiveSerializer<AssetIdList> {
  @override
  final Iterable<Type> types = const [AssetIdList, _$AssetIdList];

  @override
  final String wireName = r'AssetIdList';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    AssetIdList object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'asset_ids';
    yield serializers.serialize(
      object.assetIds,
      specifiedType: const FullType(BuiltList, [FullType(String)]),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    AssetIdList object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required AssetIdListBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'asset_ids':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(BuiltList, [FullType(String)]),
          ) as BuiltList<String>;
          result.assetIds.replace(valueDes);
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  AssetIdList deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = AssetIdListBuilder();
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

