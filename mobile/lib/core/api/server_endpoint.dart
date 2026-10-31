/// The browse client's view of the paired server: which endpoint to call
/// (the engine picks LAN or remote, R9), its pin, and the access token.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:pictunnel_api/pictunnel_api.dart';

import '../engine/engine.dart';
import 'api_client.dart';
import 'pinning.dart';

/// Caches `engine.serverInfo()` for a short while so each request does not
/// cross the bridge. Invalidated when a request fails to connect, so the next
/// one picks up the engine's new endpoint choice.
class ServerEndpoint {
  ServerEndpoint(
    this._engine, {
    this.ttl = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Engine _engine;
  final Duration ttl;
  final DateTime Function() _now;
  ServerConnection? _cached;
  DateTime? _at;

  /// The last known connection, if any (used where a sync answer is needed,
  /// such as building a playback URL).
  ServerConnection? get current => _cached;

  Future<ServerConnection> resolve() async {
    final c = _cached, at = _at;
    if (c != null && at != null && _now().difference(at) < ttl) return c;
    final fresh = await _engine.serverInfo();
    if (fresh == null) {
      _cached = null;
      throw PlatformException(code: 'not_paired');
    }
    _cached = fresh;
    _at = _now();
    return fresh;
  }

  void invalidate() => _at = null;

  /// The endpoint without a trailing slash.
  static String baseOf(ServerConnection c) =>
      c.activeEndpoint.replaceAll(RegExp(r'/+$'), '');
}

/// Supplies tokens from the engine (`getAccessToken`), which owns refresh.
class EngineTokenProvider implements TokenProvider {
  EngineTokenProvider(this._engine);
  final Engine _engine;

  @override
  Future<String> accessToken() => _engine.getAccessToken();
}

/// Points every request at the engine's active endpoint and adds the
/// `PicTunnel-Client` header (P§2 version gate).
class EndpointInterceptor extends Interceptor {
  EndpointInterceptor(this._endpoint, {required this.clientHeader});

  final ServerEndpoint _endpoint;
  final String clientHeader;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final c = await _endpoint.resolve();
      options.baseUrl = ServerEndpoint.baseOf(c);
      options.headers['PicTunnel-Client'] = clientHeader;
      handler.next(options);
    } catch (e, st) {
      handler.reject(
        DioException(requestOptions: options, error: e, stackTrace: st),
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response == null) _endpoint.invalidate();
    handler.next(err);
  }
}

/// `android/<version>` or `ios/<version>`.
String clientHeaderFor(String version) =>
    '${Platform.isIOS ? 'ios' : 'android'}/$version';

/// The browse/account client: endpoint from the engine, tokens from the
/// engine, and certificates accepted when the system trusts them or the leaf
/// matches the full pinned SPKI fingerprint (`fpFull`).
PictunnelApi buildServerApi({
  required ServerEndpoint endpoint,
  required TokenProvider tokens,
  required String clientHeader,
  HttpClientAdapter? adapter,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
  dio.httpClientAdapter =
      adapter ??
      IOHttpClientAdapter(
        createHttpClient: () => pinnedHttpClient(() => endpoint.current?.fpFull),
      );
  dio.interceptors.add(
    EndpointInterceptor(endpoint, clientHeader: clientHeader),
  );
  final base = endpoint.current;
  return createApiClient(
    baseUrl: base == null ? '' : ServerEndpoint.baseOf(base),
    tokens: tokens,
    dio: dio,
  );
}
