//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:pictunnel_api/src/model/client_versions.dart';
import 'package:pictunnel_api/src/model/upload_limits.dart';
import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'server_info.g.dart';

/// ServerInfo
///
/// Properties:
/// * [serverId] 
/// * [name] 
/// * [version] 
/// * [apiVersion] 
/// * [minClientVersion] 
/// * [capabilities] 
/// * [upload] 
/// * [time] - Server clock, for skew diagnostics only.
@BuiltValue()
abstract class ServerInfo implements Built<ServerInfo, ServerInfoBuilder> {
  @BuiltValueField(wireName: r'server_id')
  String get serverId;

  @BuiltValueField(wireName: r'name')
  String get name;

  @BuiltValueField(wireName: r'version')
  String get version;

  @BuiltValueField(wireName: r'api_version')
  String get apiVersion;

  @BuiltValueField(wireName: r'min_client_version')
  ClientVersions get minClientVersion;

  @BuiltValueField(wireName: r'capabilities')
  BuiltList<String> get capabilities;

  @BuiltValueField(wireName: r'upload')
  UploadLimits get upload;

  /// Server clock, for skew diagnostics only.
  @BuiltValueField(wireName: r'time')
  DateTime get time;

  ServerInfo._();

  factory ServerInfo([void updates(ServerInfoBuilder b)]) = _$ServerInfo;

  @BuiltValueHook(initializeBuilder: true)
  static void _defaults(ServerInfoBuilder b) => b;

  @BuiltValueSerializer(custom: true)
  static Serializer<ServerInfo> get serializer => _$ServerInfoSerializer();
}

class _$ServerInfoSerializer implements PrimitiveSerializer<ServerInfo> {
  @override
  final Iterable<Type> types = const [ServerInfo, _$ServerInfo];

  @override
  final String wireName = r'ServerInfo';

  Iterable<Object?> _serializeProperties(
    Serializers serializers,
    ServerInfo object, {
    FullType specifiedType = FullType.unspecified,
  }) sync* {
    yield r'server_id';
    yield serializers.serialize(
      object.serverId,
      specifiedType: const FullType(String),
    );
    yield r'name';
    yield serializers.serialize(
      object.name,
      specifiedType: const FullType(String),
    );
    yield r'version';
    yield serializers.serialize(
      object.version,
      specifiedType: const FullType(String),
    );
    yield r'api_version';
    yield serializers.serialize(
      object.apiVersion,
      specifiedType: const FullType(String),
    );
    yield r'min_client_version';
    yield serializers.serialize(
      object.minClientVersion,
      specifiedType: const FullType(ClientVersions),
    );
    yield r'capabilities';
    yield serializers.serialize(
      object.capabilities,
      specifiedType: const FullType(BuiltList, [FullType(String)]),
    );
    yield r'upload';
    yield serializers.serialize(
      object.upload,
      specifiedType: const FullType(UploadLimits),
    );
    yield r'time';
    yield serializers.serialize(
      object.time,
      specifiedType: const FullType(DateTime),
    );
  }

  @override
  Object serialize(
    Serializers serializers,
    ServerInfo object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return _serializeProperties(serializers, object, specifiedType: specifiedType).toList();
  }

  void _deserializeProperties(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
    required List<Object?> serializedList,
    required ServerInfoBuilder result,
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
        case r'name':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.name = valueDes;
          break;
        case r'version':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.version = valueDes;
          break;
        case r'api_version':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(String),
          ) as String;
          result.apiVersion = valueDes;
          break;
        case r'min_client_version':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(ClientVersions),
          ) as ClientVersions;
          result.minClientVersion.replace(valueDes);
          break;
        case r'capabilities':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(BuiltList, [FullType(String)]),
          ) as BuiltList<String>;
          result.capabilities.replace(valueDes);
          break;
        case r'upload':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(UploadLimits),
          ) as UploadLimits;
          result.upload.replace(valueDes);
          break;
        case r'time':
          final valueDes = serializers.deserialize(
            value,
            specifiedType: const FullType(DateTime),
          ) as DateTime;
          result.time = valueDes;
          break;
        default:
          unhandled.add(key);
          unhandled.add(value);
          break;
      }
    }
  }

  @override
  ServerInfo deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    final result = ServerInfoBuilder();
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

