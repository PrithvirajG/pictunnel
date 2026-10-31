import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/app/app.dart';
import 'package:pictunnel/app/router.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/core/engine/fake_engine.dart';
import 'package:pictunnel/features/pairing/qr_scanner_view.dart';

import '../support/fake_qr_scanner.dart';

const goodUri = 'pictunnel://pair?v=1&sid=srv-1&code=ABCD-EFGH-JK'
    '&fp=AB12CD34EF56GH78IJ90KL12MN34OP56QR78ST90UV12'
    '&u=https%3A%2F%2F192.168.1.20%3A8443&u=https%3A%2F%2Fhome.example.com';

class Harness {
  Harness(this.engine, this.scanner, this.container);
  final FakeEngine engine;
  final FakeQrScanner scanner;
  final ProviderContainer container;
  String get location => container
      .read(routerProvider)
      .routerDelegate
      .currentConfiguration
      .uri
      .path;
}

ServerConnection paired() => ServerConnection(
      serverId: 's',
      name: 'n',
      activeEndpoint: 'https://x',
      onLan: true,
      fp16: 'f',
      fpFull: 'f',
    );

Future<Harness> pump(WidgetTester t, {FakeEngine? engine}) async {
  t.view.physicalSize = const Size(390 * 2, 844 * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final e = engine ?? FakeEngine();
  final s = FakeQrScanner();
  final c = ProviderContainer(
    overrides: [
      engineProvider.overrideWithValue(e),
      qrScannerProvider.overrideWithValue(s),
    ],
  );
  addTearDown(c.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(container: c, child: const PicTunnelApp()),
  );
  await t.pumpAndSettle();
  return Harness(e, s, c);
}

Future<void> scanGood(WidgetTester t, Harness h) async {
  h.scanner.scan(goodUri);
  await t.pumpAndSettle();
}

void main() {
  group('pair screen', () {
    testWidgets('unpaired app lands on the pair screen', (t) async {
      final h = await pump(t);
      expect(h.location, '/pair');
      expect(find.text('Pair with your server'), findsOneWidget);
      expect(
        find.text(
          'On your computer, open PicTunnel and choose Add phone. '
          'Point the camera at the code it shows.',
        ),
        findsOneWidget,
      );
      expect(find.text('Enter a server address instead'), findsOneWidget);
      expect(find.byKey(const Key('fake-scanner')), findsOneWidget);
      await expectLater(
        find.byType(PicTunnelApp),
        matchesGoldenFile('../goldens/pair_screen.png'),
      );
    });

    testWidgets('paired app skips pairing', (t) async {
      final h = await pump(t, engine: FakeEngine(connection: paired()));
      expect(h.location, '/photos');
    });

    testWidgets('scanning a valid code shows the server-found card', (t) async {
      final h = await pump(t);
      await scanGood(t, h);
      expect(find.text('Server found'), findsOneWidget);
      expect(find.text('On this network'), findsOneWidget);
      expect(find.text('https://192.168.1.20:8443'), findsOneWidget);
      expect(find.text('SECURITY CODE'), findsOneWidget);
      expect(find.text('AB12 CD34 EF56 GH78'), findsOneWidget);
      expect(
        find.text("Matches the code on your server's screen."),
        findsOneWidget,
      );
      expect(find.text('Connect and start backup'), findsOneWidget);
      await expectLater(
        find.byType(PicTunnelApp),
        matchesGoldenFile('../goldens/pair_server_found.png'),
      );
    });

    testWidgets('remote-only endpoint is not labelled as this network',
        (t) async {
      final h = await pump(t);
      h.scanner.scan(
        'pictunnel://pair?v=1&sid=s&code=ABCD-EFGH-JK&fp=AB12CD34EF56GH78IJ'
        '&u=https%3A%2F%2Fhome.example.com',
      );
      await t.pumpAndSettle();
      expect(find.text('Server found'), findsOneWidget);
      expect(find.text('On this network'), findsNothing);
    });

    const badCases = {
      'invalid_scheme': 'That is not a PicTunnel code.',
      'unsupported_version': 'This code is from a newer PicTunnel.',
      'invalid_code': 'That code is not valid.',
      'insecure_endpoint': 'This code points at an unencrypted address',
    };
    const badUris = {
      'invalid_scheme': 'https://example.com',
      'unsupported_version': 'pictunnel://pair?v=2',
      'invalid_code':
          'pictunnel://pair?v=1&sid=s&code=nope&fp=x&u=https%3A%2F%2Fa',
      'insecure_endpoint':
          'pictunnel://pair?v=1&sid=s&code=ABCD-EFGH-JK&fp=x&u=http%3A%2F%2Fa',
    };
    for (final c in badCases.entries) {
      testWidgets('bad QR (${c.key}) shows copy and keeps scanning', (t) async {
        final h = await pump(t);
        h.scanner.scan(badUris[c.key]!);
        await t.pumpAndSettle();
        expect(find.textContaining(c.value), findsOneWidget);
        expect(find.text('Server found'), findsNothing);
        expect(h.engine.pairRequests, isEmpty);
      });
    }

    testWidgets('connect pairs with the scanned URI and opens Photos',
        (t) async {
      final h = await pump(t);
      await scanGood(t, h);
      await t.tap(find.text('Connect and start backup'));
      await t.pumpAndSettle();
      expect(h.engine.pairRequests, hasLength(1));
      expect(h.engine.pairRequests.single.qrUri, goodUri);
      expect(h.engine.startCalls, 1);
      expect(h.location, '/photos');
    });

    testWidgets('expired code shows the new-code copy', (t) async {
      final h = await pump(t);
      h.engine.pairError = PlatformException(code: 'pairing_code_invalid');
      await scanGood(t, h);
      await t.tap(find.text('Connect and start backup'));
      await t.pumpAndSettle();
      expect(
          find.textContaining('expired or was already used'), findsOneWidget);
      expect(h.location, '/pair');
    });

    testWidgets('pinMismatchShowsPairAgain', (t) async {
      final h = await pump(t);
      h.engine.pairError = PlatformException(code: 'pin_mismatch');
      await scanGood(t, h);
      await t.tap(find.text('Connect and start backup'));
      await t.pumpAndSettle();

      expect(find.textContaining('security certificate has changed'),
          findsOneWidget);
      expect(find.text('Pair again'), findsOneWidget);
      expect(find.text('Connect and start backup'), findsNothing);
      expect(h.location, '/pair');
      // Nothing is retried automatically after the refusal.
      expect(h.engine.pairRequests, hasLength(1));

      await t.tap(find.text('Pair again'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('fake-scanner')), findsOneWidget);
      expect(find.text('Pair again'), findsNothing);
      expect(h.engine.pairRequests, hasLength(1));
    });

    testWidgets('needsRepair sends a paired app back to pairing', (t) async {
      final h = await pump(t, engine: FakeEngine(connection: paired()));
      expect(h.location, '/photos');
      h.engine.triggerRepair();
      await t.pumpAndSettle();
      expect(h.location, '/pair');
    });
  });

  group('manual server entry', () {
    Future<Harness> openManual(WidgetTester t, {FakeEngine? engine}) async {
      final h = await pump(t, engine: engine);
      await t.tap(find.text('Enter a server address instead'));
      await t.pumpAndSettle();
      return h;
    }

    String fieldText(WidgetTester t, String key) =>
        t.widget<TextField>(find.byKey(Key(key))).controller!.text;

    testWidgets('lists mDNS suggestions and fills the field', (t) async {
      final e = FakeEngine()..discovered = ['https://192.168.1.20:8443'];
      await openManual(t, engine: e);
      expect(find.byKey(const Key('server-url')), findsOneWidget);
      await t.tap(find.text('https://192.168.1.20:8443'));
      await t.pumpAndSettle();
      expect(fieldText(t, 'server-url'), 'https://192.168.1.20:8443');
    });

    testWidgets('fingerprint comparison then pair with the pin', (t) async {
      final h = await openManual(t);
      await t.enterText(
          find.byKey(const Key('server-url')), '192.168.1.20:8443');
      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();

      expect(h.engine.trustRequests, ['https://192.168.1.20:8443']);
      expect(find.text('Home server'), findsOneWidget);
      expect(find.text('SECURITY CODE'), findsOneWidget);
      expect(find.text('AB12 CD34 EF56 GH78'), findsOneWidget);
      await expectLater(
        find.byType(PicTunnelApp),
        matchesGoldenFile('../goldens/pair_manual_fingerprint.png'),
      );

      await t.enterText(find.byKey(const Key('pair-code')), 'abcd-efgh-jk');
      await t.tap(find.text('Connect and start backup'));
      await t.pumpAndSettle();

      final r = h.engine.pairRequests.single;
      expect(r.serverUrl, 'https://192.168.1.20:8443');
      expect(r.code, 'ABCD-EFGH-JK');
      expect(r.pinnedFp, h.engine.identity.fpFull);
      expect(r.qrUri, isNull);
      expect(h.location, '/photos');
    });

    testWidgets('http address is rejected before any request', (t) async {
      final h = await openManual(t);
      await t.enterText(
          find.byKey(const Key('server-url')), 'http://nas.local');
      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      expect(find.textContaining('unencrypted'), findsOneWidget);
      expect(h.engine.trustRequests, isEmpty);
    });

    testWidgets('unreachable server shows copy', (t) async {
      final e = FakeEngine()
        ..trustError = PlatformException(code: 'unreachable');
      await openManual(t, engine: e);
      await t.enterText(
          find.byKey(const Key('server-url')), 'https://nas.local');
      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      expect(find.textContaining("Can't reach your server"), findsOneWidget);
    });

    testWidgets('malformed pairing code is rejected locally', (t) async {
      final h = await openManual(t);
      await t.enterText(
          find.byKey(const Key('server-url')), 'https://nas.local');
      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('pair-code')), 'nope');
      await t.tap(find.text('Connect and start backup'));
      await t.pumpAndSettle();
      expect(find.textContaining('That code is not valid.'), findsOneWidget);
      expect(h.engine.pairRequests, isEmpty);
    });

    testWidgets('pin mismatch during manual pairing offers Pair again',
        (t) async {
      final h = await openManual(t);
      h.engine.pairError = PlatformException(code: 'pin_mismatch');
      await t.enterText(
          find.byKey(const Key('server-url')), 'https://nas.local');
      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('pair-code')), 'ABCD-EFGH-JK');
      await t.tap(find.text('Connect and start backup'));
      await t.pumpAndSettle();
      expect(find.text('Pair again'), findsOneWidget);
      await t.tap(find.text('Pair again'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('server-url')), findsOneWidget);
    });
  });
}
