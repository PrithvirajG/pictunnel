/// State machines behind the QR and manual pairing screens, plus the copy table
/// that maps [PairUriError] codes and engine errors to user-facing text
/// (spec M§8).
library;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/engine/engine.dart';
import '../../core/pairing/pair_uri.dart';

/// Device name sent to the server. Overridable (e.g. with the real model name).
final deviceNameProvider = Provider<String>((_) => 'My phone');

/// A user-facing pairing failure.
class PairFailure {
  const PairFailure(this.code, this.message);

  /// A [PairUriError] code or an engine [PlatformException] code.
  final String code;
  final String message;

  /// The pinned certificate no longer matches: refuse and offer a fresh pair.
  bool get canPairAgain => code == 'pin_mismatch';
}

const _copy = <String, String>{
  // P§10.3 parse errors.
  'invalid_scheme':
      'That is not a PicTunnel code. Open Add phone on your computer and scan the code it shows.',
  'unsupported_version':
      'This code is from a newer PicTunnel. Update the app and try again.',
  'missing_server_id':
      'That code is incomplete. Show a new code on your computer.',
  'invalid_code': 'That code is not valid. Check it and try again.',
  'missing_fingerprint':
      'That code is incomplete. Show a new code on your computer.',
  'missing_endpoint':
      'That code does not say where your server is. Show a new code on your computer.',
  'insecure_endpoint':
      'This code points at an unencrypted address, so PicTunnel will not use it.',
  // Engine errors (PlatformException.code).
  'pin_mismatch':
      "This server's security certificate has changed. If you reinstalled PicTunnel on your computer, pair again. Otherwise do not continue.",
  'pairing_code_invalid':
      'That code has expired or was already used. Show a new code on your computer.',
  'unreachable':
      "Can't reach your server. Check that your phone is on the same network, or that the server is online.",
  'offline': "You're offline. Connect to a network and try again.",
  'rate_limited': 'Too many attempts. Wait a minute and try again.',
  'client_too_old': 'This version of PicTunnel is too old for your server. Update the app.',
};

const _fallback = "Couldn't connect to your server. Try again.";

PairFailure failureFor(Object error) {
  final code = switch (error) {
    PairUriError(:final code) => code,
    PlatformException(:final code) => code,
    _ => 'unknown',
  };
  return PairFailure(code, _copy[code] ?? _fallback);
}

/// First 16 characters in groups of four, e.g. `AB12 CD34 EF56 GH78`.
String groupFingerprint(String fp) {
  final s = fp.length > 16 ? fp.substring(0, 16) : fp;
  return [
    for (var i = 0; i < s.length; i += 4)
      s.substring(i, i + 4 > s.length ? s.length : i + 4),
  ].join(' ');
}

/// Whether [url] looks like a LAN address (private IPv4, link-local, `.local`).
bool isLanUrl(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.endsWith('.local')) return true;
  final m = RegExp(r'^(\d+)\.(\d+)\.\d+\.\d+$').firstMatch(host);
  if (m == null) return false;
  final a = int.parse(m[1]!), b = int.parse(m[2]!);
  return a == 10 ||
      (a == 192 && b == 168) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 169 && b == 254);
}

final _codeRe = RegExp(
    r'^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$');

// ---------------------------------------------------------------- QR flow --

enum QrPhase { scanning, found, connecting, failed }

class QrPairingState {
  const QrPairingState({
    this.phase = QrPhase.scanning,
    this.raw,
    this.uri,
    this.failure,
  });

  final QrPhase phase;
  final String? raw;
  final PairUri? uri;

  /// Set in [QrPhase.failed], and as a transient notice while scanning.
  final PairFailure? failure;
}

class QrPairingController extends Notifier<QrPairingState> {
  @override
  QrPairingState build() => const QrPairingState();

  void onScanned(String raw) {
    if (state.phase != QrPhase.scanning) return;
    try {
      final uri = parsePairUri(raw);
      state = QrPairingState(phase: QrPhase.found, raw: raw, uri: uri);
    } on PairUriError catch (e) {
      state = QrPairingState(failure: failureFor(e));
    }
  }

  Future<void> connect() async {
    final raw = state.raw, uri = state.uri;
    final ready = state.phase == QrPhase.found || state.phase == QrPhase.failed;
    if (!ready || raw == null || uri == null) return;
    state = QrPairingState(phase: QrPhase.connecting, raw: raw, uri: uri);
    final engine = ref.read(engineProvider);
    try {
      await engine.pair(PairRequest(
        qrUri: raw,
        code: uri.code,
        deviceName: ref.read(deviceNameProvider),
      ));
      await engine.start();
      ref.invalidate(serverConnectedProvider);
    } catch (e) {
      if (!ref.mounted) return;
      state = QrPairingState(
        phase: QrPhase.failed,
        raw: raw,
        uri: uri,
        failure: failureFor(e),
      );
    }
  }

  /// Back to the camera (also the "Pair again" action).
  void reset() => state = const QrPairingState();
}

final qrPairingProvider =
    NotifierProvider.autoDispose<QrPairingController, QrPairingState>(
        QrPairingController.new);

// ------------------------------------------------------------ manual flow --

enum ManualPhase { entry, lookingUp, verify, connecting }

class ManualPairingState {
  const ManualPairingState({
    this.phase = ManualPhase.entry,
    this.url,
    this.identity,
    this.failure,
  });

  final ManualPhase phase;
  final String? url;
  final ServerIdentity? identity;
  final PairFailure? failure;
}

class ManualPairingController extends Notifier<ManualPairingState> {
  @override
  ManualPairingState build() => const ManualPairingState();

  /// Adds `https://` to a bare host and rejects plain `http://`.
  static String? normalizeUrl(String input) {
    final t = input.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('http://')) return 'insecure';
    return t.startsWith('https://') ? t : 'https://$t';
  }

  Future<void> lookUp(String input) async {
    final url = normalizeUrl(input);
    if (url == null) return;
    if (url == 'insecure') {
      state = ManualPairingState(failure: failureFor(const PairUriError('insecure_endpoint')));
      return;
    }
    state = ManualPairingState(phase: ManualPhase.lookingUp, url: url);
    try {
      final id = await ref.read(engineProvider).trustOnFirstUse(url);
      state = ManualPairingState(
          phase: ManualPhase.verify, url: url, identity: id);
    } catch (e) {
      if (!ref.mounted) return;
      state = ManualPairingState(url: url, failure: failureFor(e));
    }
  }

  Future<void> connect(String codeInput) async {
    final id = state.identity, url = state.url;
    if (state.phase != ManualPhase.verify || id == null || url == null) return;
    final code = codeInput.trim().toUpperCase();
    if (!_codeRe.hasMatch(code)) {
      state = ManualPairingState(
        phase: ManualPhase.verify,
        url: url,
        identity: id,
        failure: failureFor(const PairUriError('invalid_code')),
      );
      return;
    }
    state = ManualPairingState(
        phase: ManualPhase.connecting, url: url, identity: id);
    final engine = ref.read(engineProvider);
    try {
      await engine.pair(PairRequest(
        serverUrl: url,
        code: code,
        deviceName: ref.read(deviceNameProvider),
        pinnedFp: id.fpFull,
      ));
      await engine.start();
      ref.invalidate(serverConnectedProvider);
    } catch (e) {
      if (!ref.mounted) return;
      state = ManualPairingState(
        phase: ManualPhase.verify,
        url: url,
        identity: id,
        failure: failureFor(e),
      );
    }
  }

  void reset() => state = const ManualPairingState();
}

final manualPairingProvider =
    NotifierProvider.autoDispose<ManualPairingController, ManualPairingState>(
        ManualPairingController.new);

/// mDNS suggestions for the manual screen.
final discoveredServersProvider = FutureProvider.autoDispose<List<String>>(
  (ref) => ref
      .read(engineProvider)
      .discoverServers(const Duration(seconds: 3))
      .catchError((_) => <String>[]),
);
