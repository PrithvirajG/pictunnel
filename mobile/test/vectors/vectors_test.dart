import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/decisions/decide.dart';
import 'package:pictunnel/core/hashing/sha256_stream.dart';
import 'package:pictunnel/core/pairing/pair_uri.dart';

const _vectorsDir = '../api/protocol/vectors';

Map<String, Object?> _load(String rel) =>
    jsonDecode(File('$_vectorsDir/$rel').readAsStringSync())
        as Map<String, Object?>;

List<Map<String, Object?>> _cases(String rel) =>
    (_load(rel)['cases']! as List).cast<Map<String, Object?>>();

/// Counter pattern per P§10.1: byte i = (i + seed) mod 256, i in [start, end).
Stream<List<int>> _counter(Map<String, Object?> g) async* {
  final seed = (g['seed'] as int?) ?? 0;
  final length = g['length']! as int;
  final start = (g['start'] as int?) ?? 0;
  final end = (g['end'] as int?) ?? length;
  const chunk = 65536;
  for (var pos = start; pos < end; pos += chunk) {
    final n = (end - pos) < chunk ? end - pos : chunk;
    final b = List<int>.filled(n, 0);
    for (var k = 0; k < n; k++) {
      b[k] = (pos + k + seed) & 0xff;
    }
    yield b;
  }
}

Stream<List<int>> _input(Map<String, Object?> input) {
  if (input.containsKey('inline_utf8')) {
    return Stream.value(utf8.encode(input['inline_utf8']! as String));
  }
  if (input.containsKey('generate')) {
    return _counter(input['generate']! as Map<String, Object?>);
  }
  return File('../api/protocol/${input['file']}').openRead();
}

void main() {
  final counts = <String, int>{
    'hashing': 0,
    'pairing': 0,
    'client-decision': 0,
  };

  group('hashing vectors', () {
    for (final f in ['hashing/core.json', 'hashing/fixtures.json']) {
      for (final c in _cases(f)) {
        test('${c['name']}', () async {
          counts['hashing'] = counts['hashing']! + 1;
          final got = await sha256Hex(_input(c['input']! as Map<String, Object?>));
          expect(got, c['expected_sha256']);
        });
      }
    }
  });

  group('pairing vectors', () {
    for (final c in _cases('pairing/qr.json')) {
      test('${c['name']}', () {
        counts['pairing'] = counts['pairing']! + 1;
        final exp = c['expect']! as Map<String, Object?>;
        if (exp['parse'] == 'error') {
          expect(
            () => parsePairUri(c['uri']! as String),
            throwsA(isA<PairUriError>().having(
                (e) => e.code, 'code', exp['error'])),
          );
          return;
        }
        final u = parsePairUri(c['uri']! as String);
        if (exp.containsKey('server_id')) expect(u.serverId, exp['server_id']);
        if (exp.containsKey('code')) expect(u.code, exp['code']);
        if (exp.containsKey('fingerprint')) {
          expect(u.fingerprint, exp['fingerprint']);
        }
        if (exp.containsKey('endpoints')) {
          expect(u.endpoints, (exp['endpoints']! as List).cast<String>());
        }
        if (exp.containsKey('accept_connection')) {
          final conn = c['connection']! as Map<String, Object?>;
          expect(
            acceptConnection(u,
                systemTrusted: conn['system_trusted']! as bool,
                spkiSha256: conn['spki_sha256']! as String),
            exp['accept_connection'],
          );
        }
      });
    }
  });

  group('client-decision vectors (browse, pairing, setup, auth)', () {
    const flows = {'browse', 'pairing', 'setup', 'auth'};
    for (final f in [
      'append-upload',
      'auth-browse-setup',
      'check-verdicts',
      'create-upload',
      'free-up-space',
    ]) {
      for (final c in _cases('client-decisions/$f.json')) {
        final given = c['given']! as Map<String, Object?>;
        if (!flows.contains(given['flow'])) continue;
        test('${c['name']}', () {
          counts['client-decision'] = counts['client-decision']! + 1;
          final server = c['server']! as Map<String, Object?>;
          final exp = c['expect']! as Map<String, Object?>;
          final d = decide(
            Given(
              flow: given['flow']! as String,
              itemState: (given['item_state'] as String?) ?? '',
              lastAction: given['last_action']! as String,
              item: (given['item'] as Map?)?.cast<String, Object?>() ??
                  const {},
            ),
            ServerOutcome(
              status: server['status'] as int?,
              headers:
                  (server['headers'] as Map?)?.cast<String, String>() ??
                      const {},
              body: server.containsKey('problem')
                  ? problemBody(
                      server['problem']! as String, server['status']! as int)
                  : server['json'],
              transport: server['transport'] as String?,
            ),
          );
          expect(d.action, exp['action']);
          expect(d.attemptsDelta, exp['attempts_delta']);
          if (exp.containsKey('next_state')) {
            expect(d.nextState, exp['next_state']);
          }
        });
      }
    }
  });

  tearDownAll(() {
    // ignore: avoid_print
    print('VECTOR COUNTS: $counts');
  });
}
