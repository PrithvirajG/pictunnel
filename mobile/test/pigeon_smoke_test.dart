import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/engine/pigeon.g.dart';

T roundTrip<T>(T value) {
  final codec = EngineHostApi.pigeonChannelCodec;
  final decoded = codec.decodeMessage(codec.encodeMessage(value));
  expect(decoded, isA<T>());
  return decoded as T;
}

void main() {
  test('BackupStatus survives the generated codec with every field intact', () {
    final status = BackupStatus(
      backedUp: 1200,
      total: 1500,
      queued: 250,
      uploading: UploadProgress(
        localId: 'local-1',
        filename: 'IMG_0001.HEIC',
        sentBytes: 4096,
        totalBytes: 8388608,
        bytesPerSecond: 1234567.5,
      ),
      needsAttention: 3,
      skipped: 7,
      freeableBytes: 9876543210,
      paused: true,
      pauseReason: PauseReason.wifiRequired,
      lastRunAtMs: 1760000000000,
      preparing: 12,
    );

    final back = roundTrip(status);

    expect(back, status);
    expect(back.backedUp, 1200);
    expect(back.total, 1500);
    expect(back.queued, 250);
    expect(back.uploading!.localId, 'local-1');
    expect(back.uploading!.filename, 'IMG_0001.HEIC');
    expect(back.uploading!.sentBytes, 4096);
    expect(back.uploading!.totalBytes, 8388608);
    expect(back.uploading!.bytesPerSecond, 1234567.5);
    expect(back.needsAttention, 3);
    expect(back.skipped, 7);
    expect(back.freeableBytes, 9876543210);
    expect(back.paused, isTrue);
    expect(back.pauseReason, PauseReason.wifiRequired);
    expect(back.lastRunAtMs, 1760000000000);
    expect(back.preparing, 12);
  });

  test('BackupStatus keeps absent optionals null', () {
    final status = BackupStatus(
      backedUp: 0,
      total: 0,
      queued: 0,
      needsAttention: 0,
      skipped: 0,
      freeableBytes: 0,
      paused: false,
      preparing: 0,
    );

    final back = roundTrip(status);

    expect(back, status);
    expect(back.uploading, isNull);
    expect(back.pauseReason, isNull);
    expect(back.lastRunAtMs, isNull);
  });

  test('PhoneItem survives the generated codec with every field intact', () {
    final item = PhoneItem(
      localId: 'local-42',
      sha256: 'ab' * 32,
      takenAtMs: 1759000000000,
      mime: 'image/heic',
      size: 3145728,
      width: 4032,
      height: 3024,
      durationMs: 2500,
      state: ItemState.needsAttention,
      assetId: 'asset-9',
      isLivePhoto: true,
    );

    final back = roundTrip(item);

    expect(back, item);
    expect(back.localId, 'local-42');
    expect(back.sha256, 'ab' * 32);
    expect(back.takenAtMs, 1759000000000);
    expect(back.mime, 'image/heic');
    expect(back.size, 3145728);
    expect(back.width, 4032);
    expect(back.height, 3024);
    expect(back.durationMs, 2500);
    expect(back.state, ItemState.needsAttention);
    expect(back.assetId, 'asset-9');
    expect(back.isLivePhoto, isTrue);
  });

  test('PhoneItem keeps absent optionals null', () {
    final item = PhoneItem(
      localId: 'local-1',
      takenAtMs: 1,
      mime: 'video/mp4',
      size: 1,
      state: ItemState.discovered,
      isLivePhoto: false,
    );

    final back = roundTrip(item);

    expect(back, item);
    expect(back.sha256, isNull);
    expect(back.width, isNull);
    expect(back.height, isNull);
    expect(back.durationMs, isNull);
    expect(back.assetId, isNull);
  });
}
