//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:pictunnel_api/src/model/user.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'setup_response.g.dart';

/// SetupResponse
///
/// Properties:
/// * [user] 
@BuiltValue()
abstract class SetupResponse implements Built<SetupResponse, SetupResponseBuilder> {
  @BuiltValueField(wireName: r'user')
  User get user;

  SetupResponse._();

  factory SetupResponse([void updates(SetupResponseBuilder b)]) = _$SetupResponse;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(SetupResponseBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<SetupResponse> get serializer => _$SetupResponseSerializer();
}

class _$SetupResponseSerializer implements PrimitiveSerializer<SetupResponse> {
  @override
  final Iterable<Type> types = const [SetupResponse, _$SetupResponse];

  @override
  final String wireName = r'SetupResponse';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    SetupResponse object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'user';
    yield serializers.serialize(
      object.user,
      specifiedType: const FullType(User),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    SetupResponse object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required SetupResponseBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'user':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(User),
          ) as User;
          result.user.replace(valueDes);
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  SetupResponse deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = SetupResponseBuilder();
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

