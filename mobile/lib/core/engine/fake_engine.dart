/// In-memory [Engine] for widget tests and the debug "demo" flavor.
library;

import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;

import 'engine.dart';

class FakeEngine implements Engine {
  FakeEngine({this.connection});

  ServerConnection? connection;

  /// Thrown by [pair] / [trustOnFirstUse] when set.
  PlatformException? pairError;
  PlatformException? trustError;

  /// Returned by [discoverServers].
  List<String> discovered = [];

  ServerIdentity identity = ServerIdentity(
    serverId: 'srv-1',
    name: 'Home server',
    fp16: 'AB12CD34EF56GH78',
    fpFull: 'AB12CD34EF56GH78IJ90KL12MN34OP56QR78ST90UV12',
    url: 'https://192.168.1.20:8443',
  );

  final pairRequests = <PairRequest>[];
  final trustRequests = <String>[];
  var startCalls = 0;
  var unpairCalls = 0;

  final _status = StreamController<BackupStatus>.broadcast();
  final _items = StreamController<PhoneItem>.broadcast();
  final _repair = StreamController<void>.broadcast();

  @override
  Stream<BackupStatus> get status$ => _status.stream;
  @override
  Stream<PhoneItem> get items$ => _items.stream;
  @override
  Stream<void> get needsRepair$ => _repair.stream;

  void emitStatus(BackupStatus s) => _status.add(s);
  void emitItem(PhoneItem i) => _items.add(i);

  /// Simulates refresh-token reuse: credentials wiped, event fired.
  void triggerRepair() {
    connection = null;
    _repair.add(null);
  }

  @override
  Future<PairResult> pair(PairRequest req) async {
    pairRequests.add(req);
    final e = pairError;
    if (e != null) throw e;
    connection = ServerConnection(
      serverId: identity.serverId,
      name: identity.name,
      activeEndpoint: req.serverUrl ?? identity.url,
      onLan: true,
      fp16: identity.fp16,
    );
    return PairResult(
      serverId: identity.serverId,
      serverName: identity.name,
      userName: 'me',
      deviceId: 'dev-1',
    );
  }

  @override
  Future<ServerIdentity> trustOnFirstUse(String serverUrl) async {
    trustRequests.add(serverUrl);
    final e = trustError;
    if (e != null) throw e;
    return identity;
  }

  @override
  Future<ServerConnection?> serverInfo() async => connection;

  @override
  Future<List<String>> discoverServers(Duration timeout) async => discovered;

  @override
  Future<void> unpair() async {
    unpairCalls++;
    connection = null;
  }

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<BackupStatus> getStatus() async => BackupStatus(
        backedUp: 0,
        total: 0,
        queued: 0,
        needsAttention: 0,
        skipped: 0,
        freeableBytes: 0,
        paused: false,
        preparing: 0,
      );
}
