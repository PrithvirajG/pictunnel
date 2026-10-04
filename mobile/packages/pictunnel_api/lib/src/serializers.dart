//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_import

import 'package:one_of_serializer/any_of_serializer.dart';
import 'package:one_of_serializer/one_of_serializer.dart';
import 'package:built_collection/built_collection.dart';
import 'package:built_value/json_object.dart';
import 'package:built_value/serializer.dart';
import 'package:built_value/standard_json_plugin.dart';
import 'package:built_value/iso_8601_date_time_serializer.dart';
import 'package:pictunnel_api/src/date_serializer.dart';
import 'package:pictunnel_api/src/model/date.dart';

import 'package:pictunnel_api/src/model/asset.dart';
import 'package:pictunnel_api/src/model/asset_id_list.dart';
import 'package:pictunnel_api/src/model/bulk_failure.dart';
import 'package:pictunnel_api/src/model/bulk_result.dart';
import 'package:pictunnel_api/src/model/change_entry.dart';
import 'package:pictunnel_api/src/model/changes_page.dart';
import 'package:pictunnel_api/src/model/check_item.dart';
import 'package:pictunnel_api/src/model/check_request.dart';
import 'package:pictunnel_api/src/model/check_response.dart';
import 'package:pictunnel_api/src/model/check_result.dart';
import 'package:pictunnel_api/src/model/client_versions.dart';
import 'package:pictunnel_api/src/model/device.dart';
import 'package:pictunnel_api/src/model/device_list.dart';
import 'package:pictunnel_api/src/model/device_patch.dart';
import 'package:pictunnel_api/src/model/device_registration.dart';
import 'package:pictunnel_api/src/model/empty_trash_result.dart';
import 'package:pictunnel_api/src/model/live_video.dart';
import 'package:pictunnel_api/src/model/login_request.dart';
import 'package:pictunnel_api/src/model/login_response.dart';
import 'package:pictunnel_api/src/model/pairing_code.dart';
import 'package:pictunnel_api/src/model/problem.dart';
import 'package:pictunnel_api/src/model/redeem_request.dart';
import 'package:pictunnel_api/src/model/redeem_response.dart';
import 'package:pictunnel_api/src/model/refresh_request.dart';
import 'package:pictunnel_api/src/model/server_info.dart';
import 'package:pictunnel_api/src/model/setup_request.dart';
import 'package:pictunnel_api/src/model/setup_response.dart';
import 'package:pictunnel_api/src/model/snapshot_page.dart';
import 'package:pictunnel_api/src/model/token_pair.dart';
import 'package:pictunnel_api/src/model/tombstone.dart';
import 'package:pictunnel_api/src/model/tombstone_page.dart';
import 'package:pictunnel_api/src/model/upload_limits.dart';
import 'package:pictunnel_api/src/model/upload_ref.dart';
import 'package:pictunnel_api/src/model/user.dart';

part 'serializers.g.dart';

@SerializersFor([
  Asset,
  AssetIdList,
  BulkFailure,
  BulkResult,
  ChangeEntry,
  ChangesPage,
  CheckItem,
  CheckRequest,
  CheckResponse,
  CheckResult,
  ClientVersions,
  Device,
  DeviceList,
  DevicePatch,
  DeviceRegistration,
  EmptyTrashResult,
  LiveVideo,
  LoginRequest,
  LoginResponse,
  PairingCode,
  Problem,
  RedeemRequest,
  RedeemResponse,
  RefreshRequest,
  ServerInfo,
  SetupRequest,
  SetupResponse,
  SnapshotPage,
  TokenPair,
  Tombstone,
  TombstonePage,
  UploadLimits,
  UploadRef,
  User,
])
Serializers serializers = (_$serializers.toBuilder()
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(CheckResult)]),
        () => ListBuilder<CheckResult>(),
      )
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(Device)]),
        () => ListBuilder<Device>(),
      )
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(ChangeEntry)]),
        () => ListBuilder<ChangeEntry>(),
      )
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(BulkFailure)]),
        () => ListBuilder<BulkFailure>(),
      )
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(CheckItem)]),
        () => ListBuilder<CheckItem>(),
      )
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(String)]),
        () => ListBuilder<String>(),
      )
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(Tombstone)]),
        () => ListBuilder<Tombstone>(),
      )
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(Asset)]),
        () => ListBuilder<Asset>(),
      )
      ..add(const OneOfSerializer())
      ..add(const AnyOfSerializer())
      ..add(const DateSerializer())
      ..add(Iso8601DateTimeSerializer())
    ).build();

Serializers standardSerializers =
    (serializers.toBuilder()..addPlugin(StandardJsonPlugin())).build();
