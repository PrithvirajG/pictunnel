//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_collection/built_collection.dart';
import 'package:pictunnel_api/src/model/tombstone.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'tombstone_page.g.dart';

/// TombstonePage
///
/// Properties:
/// * [tombstones] 
/// * [nextCursor] 
/// * [hasMore] 
@BuiltValue()
abstract class TombstonePage implements Built<TombstonePage, TombstonePageBuilder> {
  @BuiltValueField(wireName: r'tombstones')
  BuiltList<Tombstone> get tombstones;

  @BuiltValueField(wireName: r'next_cursor')
  String? get nextCursor;

  @BuiltValueField(wireName: r'has_more')
  bool get hasMore;

  TombstonePage._();

  factory TombstonePage([void updates(TombstonePageBuilder b)]) = _$TombstonePage;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(TombstonePageBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<TombstonePage> get serializer => _$TombstonePageSerializer();
}

class _$TombstonePageSerializer implements PrimitiveSerializer<TombstonePage> {
  @override
  final Iterable<Type> types = const [TombstonePage, _$TombstonePage];

  @override
  final String wireName = r'TombstonePage';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    TombstonePage object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'tombstones';
    yield serializers.serialize(
      object.tombstones,
      specifiedType: const FullType(BuiltList, [FullType(Tombstone)]),
    );
    if (object.nextCursor != null) {
      yield r'next_cursor';
      yield serializers.serialize(
        object.nextCursor,
        specifiedType: const FullType.nullable(String),
      );
    }
    yield r'has_more';
    yield serializers.serialize(
      object.hasMore,
      specifiedType: const FullType(bool),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    TombstonePage object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required TombstonePageBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'tombstones':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(BuiltList, [FullType(Tombstone)]),
          ) as BuiltList<Tombstone>;
          result.tombstones.replace(valueDes);
          break;
        case r'next_cursor':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(String),
          ) as String?;
          if (valueDes == null) continue;
          result.nextCursor = valueDes;
          break;
        case r'has_more':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(bool),
          ) as bool;
          result.hasMore = valueDes;
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  TombstonePage deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = TombstonePageBuilder();
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

