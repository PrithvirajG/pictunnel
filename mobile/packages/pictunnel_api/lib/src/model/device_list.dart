//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:pictunnel_api/src/model/device.dart';
import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'device_list.g.dart';

/// DeviceList
///
/// Properties:
/// * [devices] 
@BuiltValue()
abstract class DeviceList implements Built<DeviceList, DeviceListBuilder> {
  @BuiltValueField(wireName: r'devices')
  BuiltList<Device> get devices;

  DeviceList._();

  factory DeviceList([void updates(DeviceListBuilder b)]) = _$DeviceList;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(DeviceListBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<DeviceList> get serializer => _$DeviceListSerializer();
}

class _$DeviceListSerializer implements PrimitiveSerializer<DeviceList> {
  @override
  final Iterable<Type> types = const [DeviceList, _$DeviceList];

  @override
  final String wireName = r'DeviceList';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    DeviceList object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'devices';
    yield serializers.serialize(
      object.devices,
      specifiedType: const FullType(BuiltList, [FullType(Device)]),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    DeviceList object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required DeviceListBuilder result,
    required List<Object?> unhandled,
  }) {
    for (var i = 0; i < serializedList.length; i += 2) {
      final key = serializedList[i] as String;
      final value = serializedList[i + 1];
      switch (key) {
        case r'devices':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(BuiltList, [FullType(Device)]),
          ) as BuiltList<Device>;
          result.devices.replace(valueDes);
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  DeviceList deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = DeviceListBuilder();
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

