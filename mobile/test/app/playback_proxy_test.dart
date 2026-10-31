import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/api/pinning.dart';
import 'package:pictunnel/core/api/playback_proxy.dart';

// Self-signed P-256 certificate (CN=pictunnel.test, SAN 127.0.0.1) and its
// key, for a local TLS "server". _fp is `openssl pkey -pubin -outform der |
// sha256 | base64url` of its public key.
const _certPem = '''
-----BEGIN CERTIFICATE-----
MIIBqDCCAU6gAwIBAgIUXagssRplVL4D9waYYKoonpAUiT8wCgYIKoZIzj0EAwIw
GTEXMBUGA1UEAwwOcGljdHVubmVsLnRlc3QwHhcNMjYxMDMxMTExMTUwWhcNMzYx
MDI4MTExMTUwWjAZMRcwFQYDVQQDDA5waWN0dW5uZWwudGVzdDBZMBMGByqGSM49
AgEGCCqGSM49AwEHA0IABHZJQrJHsH+uQW+vgKNKM9e8xhwl4PtIM1OT7l7e3Zuu
13nf4QimmhLxgItljqvQpKg8/Rn/JwVQ+OKTtntsEoCjdDByMB0GA1UdDgQWBBSb
c9AMOlJvyeL5Cm000Hye9K+m4zAfBgNVHSMEGDAWgBSbc9AMOlJvyeL5Cm000Hye
9K+m4zAPBgNVHRMBAf8EBTADAQH/MB8GA1UdEQQYMBaCDnBpY3R1bm5lbC50ZXN0
hwR/AAABMAoGCCqGSM49BAMCA0gAMEUCIDY2nMLPOqgRbv7hNtExCgtpeVIv2oBb
Ajo2POnKAZF7AiEAmZa8+/rwSig80tNnvYIxESX8YLy4JUsvRlrWwApfUds=
-----END CERTIFICATE-----
''';
const _keyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgz9VGEE5sRAwMZmdY
pl0qqvZ5uS1FE+kwrhyydzMAVWihRANCAAR2SUKyR7B/rkFvr4CjSjPXvMYcJeD7
SDNTk+5e3t2brtd53+EIppoS8YCLZY6r0KSoPP0Z/ycFUPjik7Z7bBKA
-----END PRIVATE KEY-----
''';
const _fp = '4sgVKWyWLidX4qYlKUke9eZrPFdVS5SeUnJqplYSdKw';

/// A TLS playback endpoint serving [body] with HTTP range support; records
/// what each request carried.
class _Upstream {
  _Upstream._(this.server);
  final HttpServer server;
  final requests = <({String path, String? auth, String? range})>[];
  final body = Uint8List.fromList(List<int>.generate(1000, (i) => i % 251));

  static Future<_Upstream> start() async {
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_certPem))
      ..usePrivateKeyBytes(utf8.encode(_keyPem));
    final u = _Upstream._(
      await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx),
    );
    u.server.listen(u._handle);
    return u;
  }

  Uri get playback => Uri.parse(
    'https://127.0.0.1:${server.port}/api/v1/assets/v1/playback',
  );

  Future<void> _handle(HttpRequest req) async {
    final range = req.headers.value(HttpHeaders.rangeHeader);
    requests.add((
      path: req.uri.path,
      auth: req.headers.value(HttpHeaders.authorizationHeader),
      range: range,
    ));
    final res = req.response
      ..headers.contentType = ContentType('video', 'mp4')
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final m = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (m != null) {
      final start = int.parse(m[1]!);
      final end = m[2]!.isEmpty ? body.length - 1 : int.parse(m[2]!);
      res
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${body.length}',
        )
        ..contentLength = end - start + 1
        ..add(body.sublist(start, end + 1));
    } else {
      res
        ..contentLength = body.length
        ..add(body);
    }
    await res.close();
  }
}

Future<PlaybackProxy> _proxy(_Upstream up, {String pin = _fp}) =>
    PlaybackProxy.start(
      client: pinnedHttpClient(() => pin),
      upstream: () async => up.playback,
      headers: () async => {'Authorization': 'Bearer pt_at_video'},
    );

Future<({int status, HttpHeaders headers, List<int> body})> _get(
  Uri url, {
  String? range,
}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (status: res.statusCode, headers: res.headers, body: body);
  } finally {
    client.close(force: true);
  }
}

void main() {
  // flutter_test answers every HttpClient with a mock 400; this test talks to
  // real loopback sockets.
  setUpAll(() => HttpOverrides.global = null);

  late _Upstream up;
  setUp(() async => up = await _Upstream.start());
  tearDown(() => up.server.close(force: true));

  test('listens on loopback only, with a token in the path', () async {
    final proxy = await _proxy(up);
    addTearDown(proxy.close);
    expect(proxy.url.scheme, 'http');
    expect(proxy.url.host, '127.0.0.1');
    expect(proxy.url.pathSegments, hasLength(2));
    expect(proxy.url.pathSegments.first.length, greaterThanOrEqualTo(40));
    final other = await _proxy(up);
    addTearDown(other.close);
    expect(other.url.path, isNot(proxy.url.path), reason: 'per-session token');
  });

  test('passes a Range through: 206, Content-Range and the bytes', () async {
    final proxy = await _proxy(up);
    addTearDown(proxy.close);
    final r = await _get(proxy.url, range: 'bytes=100-199');
    expect(r.status, HttpStatus.partialContent);
    expect(r.headers.value(HttpHeaders.contentRangeHeader), 'bytes 100-199/1000');
    expect(r.headers.value(HttpHeaders.contentLengthHeader), '100');
    expect(r.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(r.headers.contentType?.mimeType, 'video/mp4');
    expect(r.body, up.body.sublist(100, 200));
    expect(up.requests.single.range, 'bytes=100-199');
    expect(up.requests.single.path, '/api/v1/assets/v1/playback');
  });

  test('adds the bearer token upstream; a whole GET streams 200', () async {
    final proxy = await _proxy(up);
    addTearDown(proxy.close);
    final r = await _get(proxy.url);
    expect(r.status, HttpStatus.ok);
    expect(r.body, up.body);
    expect(up.requests.single.auth, 'Bearer pt_at_video');
    expect(up.requests.single.range, isNull);
  });

  test('rejects requests without the session token', () async {
    final proxy = await _proxy(up);
    addTearDown(proxy.close);
    final base = proxy.url;
    final token = base.pathSegments.first;
    final wrong = token.replaceRange(
      token.length - 1,
      token.length,
      token.endsWith('A') ? 'B' : 'A',
    );
    for (final path in [
      '/',
      '/playback',
      '/$wrong/playback',
      '/$token',
      '/$token/other',
      '/$token/playback/extra',
    ]) {
      final r = await _get(base.replace(path: path));
      expect(r.status, HttpStatus.forbidden, reason: path);
    }
    expect(up.requests, isEmpty, reason: 'nothing reached the server');
  });

  test('enforces the full pin: a different pin never reaches the server', () async {
    final wrongLast = '${_fp.substring(0, _fp.length - 1)}x';
    for (final pin in [wrongLast, _fp.substring(0, 16)]) {
      final proxy = await _proxy(up, pin: pin);
      final r = await _get(proxy.url, range: 'bytes=0-9');
      await proxy.close();
      expect(r.status, HttpStatus.badGateway, reason: pin);
    }
    expect(up.requests, isEmpty);
  });

  test('close stops the proxy', () async {
    final proxy = await _proxy(up);
    final url = proxy.url;
    await proxy.close();
    await expectLater(_get(url), throwsA(isA<SocketException>()));
  });
}
