//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'client_versions.g.dart';

/// ClientVersions
///
/// Properties:
/// * [android] 
/// * [ios] 
/// * [web] 
@BuiltValue()
abstract class ClientVersions implements Built<ClientVersions, ClientVersionsBuilder> {
  @BuiltValueField(wireName: r'android')
  String get android;

  @BuiltValueField(wireName: r'ios')
  String get ios;

  @BuiltValueField(wireName: r'web')
  String get web;

  ClientVersions._();

  factory ClientVersions([void updates(ClientVersionsBuilder b)]) = _$ClientVersions;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(ClientVersionsBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<ClientVersions> get serializer => _$ClientVersionsSerializer();
}

class _$ClientVersionsSerializer implements PrimitiveSerializer<ClientVersions> {
  @override
  final Iterable<Type> types = const [ClientVersions, _$ClientVersions];

  @override
  final String wireName = r'ClientVersions';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    ClientVersions object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'android';
    yield serializers.serialize(
      object.android,
      specifiedType: const FullType(String),
    );
    yield r'ios';
    yield serializers.serialize(
      object.ios,
      specifiedType: const FullType(String),
    );
    yield r'web';
    yield serializers.serialize(
      object.web,
      specifiedType: const FullType(String),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    ClientVersions object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required ClientVersionsBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'android':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.android = valueDes;
          break;
        case r'ios':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.ios = valueDes;
          break;
        case r'web':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.web = valueDes;
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  ClientVersions deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = ClientVersionsBuilder();
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

