//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:pictunnel_api/src/model/user.dart';
import 'package:pictunnel_api/src/model/device.dart';
import 'package:pictunnel_api/src/model/token_pair.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'redeem_response.g.dart';

/// RedeemResponse
///
/// Properties:
/// * [serverId] 
/// * [user] 
/// * [device] 
/// * [tokens] 
@BuiltValue()
abstract class RedeemResponse implements Built<RedeemResponse, RedeemResponseBuilder> {
  @BuiltValueField(wireName: r'server_id')
  String get serverId;

  @BuiltValueField(wireName: r'user')
  User get user;

  @BuiltValueField(wireName: r'device')
  Device get device;

  @BuiltValueField(wireName: r'tokens')
  TokenPair get tokens;

  RedeemResponse._();

  factory RedeemResponse([void updates(RedeemResponseBuilder b)]) = _$RedeemResponse;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(RedeemResponseBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<RedeemResponse> get serializer => _$RedeemResponseSerializer();
}

class _$RedeemResponseSerializer implements PrimitiveSerializer<RedeemResponse> {
  @override
  final Iterable<Type> types = const [RedeemResponse, _$RedeemResponse];

  @override
  final String wireName = r'RedeemResponse';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    RedeemResponse object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'server_id';
    yield serializers.serialize(
      object.serverId,
      specifiedType: const FullType(String),
    );
    yield r'user';
    yield serializers.serialize(
      object.user,
      specifiedType: const FullType(User),
    );
    yield r'device';
    yield serializers.serialize(
      object.device,
      specifiedType: const FullType(Device),
    );
    yield r'tokens';
    yield serializers.serialize(
      object.tokens,
      specifiedType: const FullType(TokenPair),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    RedeemResponse object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required RedeemResponseBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'server_id':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.serverId = valueDes;
          break;
        case r'user':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(User),
          ) as User;
          result.user.replace(valueDes);
          break;
        case r'device':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(Device),
          ) as Device;
          result.device.replace(valueDes);
          break;
        case r'tokens':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(TokenPair),
          ) as TokenPair;
          result.tokens.replace(valueDes);
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  RedeemResponse deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = RedeemResponseBuilder();
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

