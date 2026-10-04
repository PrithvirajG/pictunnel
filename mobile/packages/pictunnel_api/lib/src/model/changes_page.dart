//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_collection/built_collection.dart';
import 'package:pictunnel_api/src/model/change_entry.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'changes_page.g.dart';

/// ChangesPage
///
/// Properties:
/// * [changes] 
/// * [nextCursor] 
/// * [hasMore] 
@BuiltValue()
abstract class ChangesPage implements Built<ChangesPage, ChangesPageBuilder> {
  @BuiltValueField(wireName: r'changes')
  BuiltList<ChangeEntry> get changes;

  @BuiltValueField(wireName: r'next_cursor')
  String get nextCursor;

  @BuiltValueField(wireName: r'has_more')
  bool get hasMore;

  ChangesPage._();

  factory ChangesPage([void updates(ChangesPageBuilder b)]) = _$ChangesPage;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(ChangesPageBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<ChangesPage> get serializer => _$ChangesPageSerializer();
}

class _$ChangesPageSerializer implements PrimitiveSerializer<ChangesPage> {
  @override
  final Iterable<Type> types = const [ChangesPage, _$ChangesPage];

  @override
  final String wireName = r'ChangesPage';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    ChangesPage object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'changes';
    yield serializers.serialize(
      object.changes,
      specifiedType: const FullType(BuiltList, [FullType(ChangeEntry)]),
    );
    yield r'next_cursor';
    yield serializers.serialize(
      object.nextCursor,
      specifiedType: const FullType(String),
    );
    yield r'has_more';
    yield serializers.serialize(
      object.hasMore,
      specifiedType: const FullType(bool),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    ChangesPage object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required ChangesPageBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'changes':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(BuiltList, [FullType(ChangeEntry)]),
          ) as BuiltList<ChangeEntry>;
          result.changes.replace(valueDes);
          break;
        case r'next_cursor':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
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
  ChangesPage deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = ChangesPageBuilder();
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

