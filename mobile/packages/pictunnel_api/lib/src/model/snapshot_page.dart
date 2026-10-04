//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_collection/built_collection.dart';
import 'package:pictunnel_api/src/model/asset.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'snapshot_page.g.dart';

/// SnapshotPage
///
/// Properties:
/// * [cursor] - Present on the first page only. Continue with getChanges from here after the last page.
/// * [assets] 
/// * [nextPageToken] 
/// * [hasMore] 
@BuiltValue()
abstract class SnapshotPage implements Built<SnapshotPage, SnapshotPageBuilder> {
  /// Present on the first page only. Continue with getChanges from here after the last page.
  @BuiltValueField(wireName: r'cursor')
  String? get cursor;

  @BuiltValueField(wireName: r'assets')
  BuiltList<Asset> get assets;

  @BuiltValueField(wireName: r'next_page_token')
  String? get nextPageToken;

  @BuiltValueField(wireName: r'has_more')
  bool get hasMore;

  SnapshotPage._();

  factory SnapshotPage([void updates(SnapshotPageBuilder b)]) = _$SnapshotPage;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(SnapshotPageBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<SnapshotPage> get serializer => _$SnapshotPageSerializer();
}

class _$SnapshotPageSerializer implements PrimitiveSerializer<SnapshotPage> {
  @override
  final Iterable<Type> types = const [SnapshotPage, _$SnapshotPage];

  @override
  final String wireName = r'SnapshotPage';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    SnapshotPage object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    if (object.cursor != null) {
      yield r'cursor';
      yield serializers.serialize(
        object.cursor,
        specifiedType: const FullType(String),
      );
    }
    yield r'assets';
    yield serializers.serialize(
      object.assets,
      specifiedType: const FullType(BuiltList, [FullType(Asset)]),
    );
    if (object.nextPageToken != null) {
      yield r'next_page_token';
      yield serializers.serialize(
        object.nextPageToken,
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
    SnapshotPage object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required SnapshotPageBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'cursor':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(String),
          ) as String?;
          if (valueDes == null) continue;
          result.cursor = valueDes;
          break;
        case r'assets':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(BuiltList, [FullType(Asset)]),
          ) as BuiltList<Asset>;
          result.assets.replace(valueDes);
          break;
        case r'next_page_token':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(String),
          ) as String?;
          if (valueDes == null) continue;
          result.nextPageToken = valueDes;
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
  SnapshotPage deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = SnapshotPageBuilder();
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

