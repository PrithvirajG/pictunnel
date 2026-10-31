import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/app/composition.dart';
import 'package:pictunnel/app/version.dart';
import 'package:pictunnel/core/api/pinning.dart';
import 'package:pictunnel/core/engine/error_copy.dart';
import 'package:pictunnel/features/pairing/pairing_controller.dart';

// Self-signed P-256 certificate for CN=pictunnel.test; the fingerprint below
// is `openssl pkey -pubin -outform der | sha256 | base64url` of its key.
const _certB64 =
    'MIIBhzCCAS2gAwIBAgIUNbFxKhU+t2AkUXU5DnIdCq2vc/0wCgYIKoZIzj0EAwIwGTEXMBUGA1UEAwwOcGljdHVubmVsLnRlc3QwHhcNMjYxMDMxMTA0NTU2WhcNMzYxMDI4MTA0NTU2WjAZMRcwFQYDVQQDDA5waWN0dW5uZWwudGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOpsXlDtzYK3BNAxorwgEtsMhM0cUIV+5Kxovbx/j5SwCJ/pBAj1z6cqOfGj8HMk0AaK/rT0r5h9SIWNd+0pWgSjUzBRMB0GA1UdDgQWBBRJDua4T/RdO8iEmegIezD+BBEEIDAfBgNVHSMEGDAWgBRJDua4T/RdO8iEmegIezD+BBEEIDAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIBuaSR954tEBU7Hxar1zZWvodtvTEBGgHXvvVTAoIwDhAiEA0dfQ4CkR/bDjJnDqdnHeKFNUieAvuCO3vU08SoP57MQ=';
const _certFp = 'WjIsglYwYTsdbsiolN599S0DWLYEggzzWLO9-mL0C5c';

void main() {
  group('pinning', () {
    final der = Uint8List.fromList(base64.decode(_certB64));

    test('SPKI fingerprint matches openssl', () {
      expect(spkiFingerprint(der), _certFp);
    });

    test('fp16 prefix and full pin match; others do not', () {
      expect(matchesPin(der, _certFp.substring(0, 16)), isTrue);
      expect(matchesPin(der, _certFp), isTrue);
      expect(matchesPin(der, 'AAAAAAAAAAAAAAAA'), isFalse);
      expect(matchesPin(der, _certFp.substring(0, 8)), isFalse);
      expect(matchesPin(der, null), isFalse);
    });

    test('garbage is not a certificate', () {
      expect(spkiFingerprint(Uint8List.fromList([0x30, 0x03, 1, 2])), isNull);
      expect(matchesPin(Uint8List(0), _certFp), isFalse);
    });
  });

  group('device name', () {
    test('prefers the user-set name', () {
      expect(
        deviceNameFrom(name: 'Priya’s Pixel', manufacturer: 'Google'),
        'Priya’s Pixel',
      );
    });
    test('falls back to manufacturer and model', () {
      expect(
        deviceNameFrom(name: '', manufacturer: 'google', model: 'Pixel 9'),
        'Google Pixel 9',
      );
      expect(
        deviceNameFrom(manufacturer: 'samsung', model: 'Samsung Galaxy S25'),
        'Samsung Galaxy S25',
      );
      expect(deviceNameFrom(model: 'iPhone'), 'iPhone');
    });
    test('never empty, at most 64 characters', () {
      expect(deviceNameFrom(), fallbackDeviceName);
      expect(deviceNameFrom(name: 'x' * 100).length, 64);
    });
  });

  group('error copy', () {
    test('pairing codes from the engines have copy', () {
      for (final code in [
        'not_pictunnel',
        'invalid_url',
        'server_id_mismatch',
        'bad_response',
        'not_paired',
        'no_activity',
        'not_found',
        'permission',
      ]) {
        final f = failureFor(PlatformException(code: code));
        expect(f.message, isNot("Couldn't connect to your server. Try again."),
            reason: code);
      }
      expect(
        failureFor(PlatformException(code: 'http_502')).message,
        contains('error 502'),
      );
    });

    test('engine errors and free-up reasons', () {
      expect(
        engineErrorMessage(PlatformException(code: 'no_activity')),
        'Open PicTunnel and try again.',
      );
      expect(
        engineErrorMessage(PlatformException(code: 'http_404')),
        'Your server refused the request (error 404).',
      );
      expect(engineErrorMessage(StateError('x')), genericErrorCopy);
      expect(engineErrorMessage(PlatformException(code: 'weird')),
          genericErrorCopy);
      expect(freeUpSkipReason('fingerprint_changed'),
          'Changed since the backup');
      expect(freeUpSkipReason('server_conflict'),
          'Not confirmed on the server');
    });
  });

  test('appVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':')[1].trim().split('+').first, appVersion);
  });
}
