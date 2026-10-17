import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

typedef FakeHandler = FakeReply Function(RequestOptions req);

class FakeReply {
  FakeReply.json(this.status, Object body)
      : bytes = Uint8List.fromList(utf8.encode(jsonEncode(body))),
        contentType = 'application/json';
  FakeReply.bytes(this.status, List<int> b)
      : bytes = Uint8List.fromList(b),
        contentType = 'image/jpeg';

  final int status;
  final Uint8List bytes;
  final String contentType;
}

/// Tiny dio adapter returning canned replies and recording requests.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final FakeHandler handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final r = handler(options);
    return ResponseBody.fromBytes(r.bytes, r.status, headers: {
      Headers.contentTypeHeader: [r.contentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> assetJson(String id,
        {int seq = 1,
        String state = 'active',
        String takenAt = '2026-03-10T10:00:00Z',
        String filename = 'a.jpg'}) =>
    {
      'id': id,
      'sha256': 'a' * 64,
      'size_bytes': 10,
      'mime': 'image/jpeg',
      'kind': 'photo',
      'filename': filename,
      'taken_at': takenAt,
      'taken_at_offset_minutes': 0,
      'taken_at_source': 'exif',
      'state': state,
      'thumbnails_ready': true,
      'created_at': '2026-03-11T10:00:00Z',
      'updated_seq': seq,
    };

Map<String, Object?> problem(String code, int status) => {
      'type': 'urn:pictunnel:problem:$code',
      'title': code,
      'status': status,
      'code': code,
    };
