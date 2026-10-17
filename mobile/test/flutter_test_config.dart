import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _load(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// Loads the bundled fonts so goldens render deterministic text on any runner.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await _load(
    'Bricolage Grotesque',
    'assets/fonts/BricolageGrotesque-Variable.ttf',
  );
  await _load('Figtree', 'assets/fonts/Figtree-Variable.ttf');
  await testMain();
}
