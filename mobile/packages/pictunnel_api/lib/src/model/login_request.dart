//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:built_collection/built_collection.dart';
import 'package:pictunnel_api/src/model/device_registration.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'login_request.g.dart';

/// LoginRequest
///
/// Properties:
/// * [username] 
/// * [password] 
/// * [mode] 
/// * [device] 
@BuiltValue()
abstract class LoginRequest implements Built<LoginRequest, LoginRequestBuilder> {
  @BuiltValueField(wireName: r'username')
  String get username;

  @BuiltValueField(wireName: r'password')
  String get password;

  @BuiltValueField(wireName: r'mode')
  LoginRequestModeEnum get mode;
  // enum modeEnum {  tokens,  cookie,  };

  @BuiltValueField(wireName: r'device')
  DeviceRegistration? get device;

  LoginRequest._();

  factory LoginRequest([void updates(LoginRequestBuilder b)]) = _$LoginRequest;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(LoginRequestBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<LoginRequest> get serializer => _$LoginRequestSerializer();
}

class _$LoginRequestSerializer implements PrimitiveSerializer<LoginRequest> {
  @override
  final Iterable<Type> types = const [LoginRequest, _$LoginRequest];

  @override
  final String wireName = r'LoginRequest';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    LoginRequest object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'username';
    yield serializers.serialize(
      object.username,
      specifiedType: const FullType(String),
    );
    yield r'password';
    yield serializers.serialize(
      object.password,
      specifiedType: const FullType(String),
    );
    yield r'mode';
    yield serializers.serialize(
      object.mode,
      specifiedType: const FullType(LoginRequestModeEnum),
    );
    if (object.device != null) {
      yield r'device';
      yield serializers.serialize(
        object.device,
        specifiedType: const FullType(DeviceRegistration),
      );
    }
  }

  @override
  Object serialize(
    Serializers serializers,
    LoginRequest object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required LoginRequestBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'username':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.username = valueDes;
          break;
        case r'password':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.password = valueDes;
          break;
        case r'mode':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(LoginRequestModeEnum),
          ) as LoginRequestModeEnum;
          result.mode = valueDes;
          break;
        case r'device':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType.nullable(DeviceRegistration),
          ) as DeviceRegistration?;
          if (valueDes == null) continue;
          result.device.replace(valueDes);
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  LoginRequest deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = LoginRequestBuilder();
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

class LoginRequestModeEnum extends EnumClass {

  @BuiltValueEnumConst(wireName: r'tokens')
  static const LoginRequestModeEnum tokens = _$loginRequestModeEnum_tokens;
  @BuiltValueEnumConst(wireName: r'cookie')
  static const LoginRequestModeEnum cookie = _$loginRequestModeEnum_cookie;
  @BuiltValueEnumConst(wireName: r'unknown_default_open_api', fallback: true)
  static const LoginRequestModeEnum unknownDefaultOpenApi = _$loginRequestModeEnum_unknownDefaultOpenApi;

  static Serializer<LoginRequestModeEnum> get serializer => _$loginRequestModeEnumSerializer;

  const LoginRequestModeEnum._(String name): super(name);

  static BuiltSet<LoginRequestModeEnum> get values => _$loginRequestModeEnumValues;
  static LoginRequestModeEnum valueOf(String name) => _$loginRequestModeEnumValueOf(name);
}

