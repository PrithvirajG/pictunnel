/// A loopback-only HTTP proxy for video playback.
///
/// video_player (ExoPlayer, AVPlayer) checks certificates against the system
/// store only, so it rejects a self-signed PicTunnel server. The viewer hands
/// the player this proxy's `http://127.0.0.1:<port>/<token>/playback` URL
/// instead; the proxy forwards each request to the server's playback URL
/// through the pinned client (P§6.3, full SPKI pin) with the bearer token,
/// and streams the answer back unchanged (200 or 206 with Content-Range).
///
/// - It listens on 127.0.0.1 only, on a random port.
/// - Requests must carry the session's random token as the first path
///   segment; anything else gets 403 and never reaches the server.
/// - One proxy per viewer session: [close] when the viewer leaves.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'pinning.dart';

class PlaybackProxy {
  PlaybackProxy._(
    this._server,
    this._client,
    this._upstream,
    this._headers,
    this._token,
  );

  /// Starts a proxy for one stream. [client] is the pinned client (the proxy
  /// owns and closes it). [upstream] and [headers] are resolved per request,
  /// so an endpoint switch or a refreshed token applies to the next range.
  static Future<PlaybackProxy> start({
    required HttpClient client,
    required Future<Uri> Function() upstream,
    required Future<Map<String, String>> Function() headers,
    Random? random,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    client
      ..autoUncompress = false
      ..connectionTimeout ??= const Duration(seconds: 10);
    final rnd = random ?? Random.secure();
    final token = base64Url
        .encode(List<int>.generate(32, (_) => rnd.nextInt(256)))
        .replaceAll('=', '');
    final proxy = PlaybackProxy._(server, client, upstream, headers, token);
    proxy._sub = server.listen(proxy._handle);
    return proxy;
  }

  final HttpServer _server;
  final HttpClient _client;
  final Future<Uri> Function() _upstream;
  final Future<Map<String, String>> Function() _headers;
  final String _token;
  late final StreamSubscription<HttpRequest> _sub;
  bool _closed = false;

  /// The URL to hand to the player.
  Uri get url => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    path: '/$_token/playback',
  );

  /// Request headers passed on to the server (besides auth, which the proxy
  /// adds itself).
  static const _requestHeaders = [HttpHeaders.rangeHeader, 'if-range'];

  /// Response headers passed back to the player (Content-Length is set
  /// separately).
  static const _responseHeaders = [
    HttpHeaders.contentTypeHeader,
    HttpHeaders.contentRangeHeader,
    HttpHeaders.acceptRangesHeader,
    HttpHeaders.etagHeader,
    HttpHeaders.lastModifiedHeader,
    HttpHeaders.cacheControlHeader,
  ];

  bool _authorized(Uri uri) {
    final segs = uri.pathSegments;
    return segs.length == 2 &&
        constantTimeEquals(segs[0], _token) &&
        segs[1] == 'playback';
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    var started = false;
    try {
      if (!_authorized(req.uri)) {
        res.statusCode = HttpStatus.forbidden;
        await res.close();
        return;
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        res
          ..statusCode = HttpStatus.methodNotAllowed
          ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await res.close();
        return;
      }
      final up = await _client.openUrl(req.method, await _upstream());
      up.followRedirects = false;
      (await _headers()).forEach(up.headers.set);
      for (final h in _requestHeaders) {
        final v = req.headers.value(h);
        if (v != null) up.headers.set(h, v);
      }
      up.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final upRes = await up.close();

      started = true;
      res.statusCode = upRes.statusCode;
      for (final h in _responseHeaders) {
        final v = upRes.headers.value(h);
        if (v != null) res.headers.set(h, v);
      }
      if (upRes.contentLength >= 0) res.contentLength = upRes.contentLength;
      if (req.method == 'HEAD') {
        await upRes.drain<void>();
      } else {
        await res.addStream(upRes);
      }
      await res.close();
    } on Object {
      // Before the answer started: the server could not be reached or its
      // certificate failed the pin. After: the player went away mid-stream.
      if (!started) {
        try {
          res.statusCode = HttpStatus.badGateway;
        } on Object {
          // Headers already sent.
        }
      }
      try {
        await res.close();
      } on Object {
        // The player's socket is gone.
      }
    }
  }

  /// Stops listening, drops open streams and closes the pinned client.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
    await _sub.cancel();
    _client.close(force: true);
  }
}
