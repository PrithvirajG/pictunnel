import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/files/safe_name.dart';
import 'package:pictunnel/features/viewer/viewer_actions.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('pt_share_test'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// A container whose share service downloads into [temp] and records what
  /// it was asked to share (and whether the file was there at that moment).
  ({ProviderContainer c, List<String> shared, List<bool> existed}) setUpShare({
    Object? shareError,
  }) {
    final shared = <String>[];
    final existed = <bool>[];
    final c = ProviderContainer(
      overrides: [
        originalDownloaderProvider.overrideWithValue(
          (id, path) async => File(path).writeAsString('original of $id'),
        ),
        shareServiceProvider.overrideWith(
          (ref) => PlusShareService(
            ref,
            tempDir: () async => temp,
            share: (XFile f) async {
              shared.add(f.path);
              existed.add(File(f.path).existsSync());
              if (shareError != null) throw shareError;
            },
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return (c: c, shared: shared, existed: existed);
  }

  String canonical(String p) => File(p).absolute.path;

  test('a traversal filename stays inside temp and is cleaned up', () async {
    final s = setUpShare();
    for (final name in [
      '../../../../etc/passwd',
      r'..\..\evil.jpg',
      '..',
      '/abs/olute.jpg',
      'IMG_0001.HEIC',
    ]) {
      await s.c.read(shareServiceProvider).shareOriginal('a1', name, 'image/jpeg');
    }
    expect(s.existed, everyElement(isTrue));
    final root = canonical('${temp.path}/$shareFolderName');
    for (final p in s.shared) {
      expect(canonical(p), startsWith(root), reason: p);
      expect(p.split(Platform.pathSeparator).last, isNot(startsWith('.')));
    }
    expect(s.shared.map((p) => p.split(Platform.pathSeparator).last), [
      'passwd',
      'evil.jpg',
      'photo',
      'olute.jpg',
      'IMG_0001.HEIC',
    ]);
    // Every per-share folder is gone once its share completed.
    for (final p in s.shared) {
      expect(File(p).existsSync(), isFalse);
      expect(File(p).parent.existsSync(), isFalse);
    }
  });

  test('the file is removed even when sharing fails', () async {
    final s = setUpShare(shareError: StateError('sheet failed'));
    await expectLater(
      s.c.read(shareServiceProvider).shareOriginal('a1', 'x.jpg', 'image/jpeg'),
      throwsStateError,
    );
    expect(File(s.shared.single).parent.existsSync(), isFalse);
  });

  test('the startup sweep removes leftover share folders', () async {
    final stale = Directory('${temp.path}/$shareFolderName/123-0')
      ..createSync(recursive: true);
    File('${stale.path}/left.jpg').writeAsStringSync('x');
    final other = File('${temp.path}/keep.txt')..writeAsStringSync('x');
    await sweepShareFolders(temp);
    expect(stale.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
  });

  test('sanitizeFileName', () {
    expect(sanitizeFileName('a:b*c?.jpg'), 'a_b_c_.jpg');
    expect(sanitizeFileName('...hidden'), 'hidden');
    expect(sanitizeFileName(''), 'file');
    final long = sanitizeFileName('${'x' * 300}.jpeg');
    expect(long.length, 120);
    expect(long, endsWith('.jpeg'));
  });
}
