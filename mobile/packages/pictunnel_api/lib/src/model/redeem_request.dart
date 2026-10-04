//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:pictunnel_api/src/model/device_registration.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'redeem_request.g.dart';

/// RedeemRequest
///
/// Properties:
/// * [code] 
/// * [device] 
@BuiltValue()
abstract class RedeemRequest implements Built<RedeemRequest, RedeemRequestBuilder> {
  @BuiltValueField(wireName: r'code')
  String get code;

  @BuiltValueField(wireName: r'device')
  DeviceRegistration get device;

  RedeemRequest._();

  factory RedeemRequest([void updates(RedeemRequestBuilder b)]) = _$RedeemRequest;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(RedeemRequestBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<RedeemRequest> get serializer => _$RedeemRequestSerializer();
}

class _$RedeemRequestSerializer implements PrimitiveSerializer<RedeemRequest> {
  @override
  final Iterable<Type> types = const [RedeemRequest, _$RedeemRequest];

  @override
  final String wireName = r'RedeemRequest';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    RedeemRequest object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'code';
    yield serializers.serialize(
      object.code,
      specifiedType: const FullType(String),
    );
    yield r'device';
    yield serializers.serialize(
      object.device,
      specifiedType: const FullType(DeviceRegistration),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    RedeemRequest object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required RedeemRequestBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'code':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.code = valueDes;
          break;
        case r'device':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(DeviceRegistration),
          ) as DeviceRegistration;
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
  RedeemRequest deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = RedeemRequestBuilder();
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

