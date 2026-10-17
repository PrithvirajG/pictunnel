import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pictunnel_api/pictunnel_api.dart';

import '../decisions/decide.dart';

/// Supplies a valid access token. The real implementation calls
/// `EngineHostApi.getAccessToken()`, so refresh stays in the native engine.
abstract class TokenProvider {
  Future<String> accessToken();
}

/// Extracts the problem body of a failed response (JSON map, JSON bytes or
/// JSON text); null when there is none.
Object? problemBodyOf(Object? data) {
  try {
    if (data is Map) return data;
    if (data is Uint8List || data is List<int>) {
      return jsonDecode(utf8.decode(data as List<int>));
    }
    if (data is String && data.isNotEmpty) return jsonDecode(data);
  } on FormatException {
    // not JSON
  }
  return null;
}

/// Maps a dio failure onto the shared decision function's input.
ServerOutcome outcomeOf(DioException e) {
  final r = e.response;
  if (r == null) {
    final String transport;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        transport = 'timeout';
      case DioExceptionType.connectionError:
        transport = 'offline';
      default:
        transport = 'reset';
    }
    return ServerOutcome(transport: transport);
  }
  return ServerOutcome(
    status: r.statusCode,
    body: problemBodyOf(r.data),
    headers: {
      for (final h in r.headers.map.entries)
        h.key: h.value.isEmpty ? '' : h.value.first,
    },
  );
}

const _retriedKey = 'pt_token_retried';

/// Adds `Authorization: Bearer` from [TokenProvider]; on a 401 it asks the
/// provider again (which refreshes natively) and retries the request once.
class TokenInterceptor extends Interceptor {
  TokenInterceptor(this._tokens, this._dio);

  final TokenProvider _tokens;
  final Dio _dio;

  @override
  Future<void> onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    try {
      options.headers['Authorization'] =
          'Bearer ${await _tokens.accessToken()}';
      handler.next(options);
    } catch (e, st) {
      handler.reject(
          DioException(requestOptions: options, error: e, stackTrace: st));
    }
  }

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler) async {
    final req = err.requestOptions;
    if (err.response?.statusCode == 401 && req.extra[_retriedKey] != true) {
      final d = decide(
          const Given(flow: 'auth', lastAction: 'request'), outcomeOf(err));
      if (d.action == 'refresh_then_retry') {
        try {
          req.extra[_retriedKey] = true;
          req.headers['Authorization'] =
              'Bearer ${await _tokens.accessToken()}';
          return handler.resolve(await _dio.fetch<Object>(req));
        } on DioException catch (e) {
          return handler.next(e);
        } catch (_) {
          // fall through to the original error
        }
      }
    }
    handler.next(err);
  }
}

/// Builds the generated client for [baseUrl] with token injection. Pass [dio]
/// to supply a configured instance (tests inject a fake adapter).
PictunnelApi createApiClient({
  required String baseUrl,
  required TokenProvider tokens,
  Dio? dio,
}) {
  final d = dio ??
      Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
      ));
  d.options.baseUrl = baseUrl;
  return PictunnelApi(dio: d, interceptors: [TokenInterceptor(tokens, d)]);
}
