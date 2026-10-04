import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel_api/pictunnel_api.dart';

void main() {
  test('generated client exposes the server API', () {
    final api = PictunnelApi(basePathOverride: 'https://localhost:8443');
    expect(api.getServerApi(), isA<ServerApi>());
  });

  test('ServerInfo deserializes snake_case JSON', () {
    final api = PictunnelApi();
    final info = api.serializers.deserializeWith(ServerInfo.serializer, {
      'server_id': '01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f',
      'name': 'Home server',
      'version': '0.1.0',
      'api_version': '1.0',
      'min_client_version': {'android': '0.1.0', 'ios': '0.1.0', 'web': '0.1.0'},
      'capabilities': ['tus'],
      'upload': {'tus_version': '1.0.0', 'max_file_bytes': 53687091200, 'recommended_chunk_bytes': 8388608},
      'time': '2026-10-03T12:00:00Z',
    })!;
    expect(info.apiVersion, '1.0');
    expect(info.upload.recommendedChunkBytes, 8388608);
  });
}
