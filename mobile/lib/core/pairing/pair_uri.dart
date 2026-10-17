/// Parser for the pairing QR URI (sync-protocol.md §6.3, §10.3).
library;

class PairUriError implements Exception {
  const PairUriError(this.code);

  /// invalid_scheme | unsupported_version | missing_server_id | invalid_code |
  /// missing_fingerprint | missing_endpoint | insecure_endpoint
  final String code;

  @override
  String toString() => 'PairUriError($code)';
}

class PairUri {
  const PairUri({
    required this.serverId,
    required this.code,
    required this.fingerprint,
    required this.endpoints,
  });

  final String serverId;
  final String code;

  /// base64url SHA-256 of the server certificate's SPKI (unpadded).
  final String fingerprint;
  final List<String> endpoints;
}

final _codeRe = RegExp(r'^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$');

PairUri parsePairUri(String uri) {
  // Manual split: Uri.parse mishandles the authority-less "pair?..." forms
  // less predictably than doing it by hand.
  const prefix = 'pictunnel://';
  if (!uri.startsWith(prefix)) throw const PairUriError('invalid_scheme');
  final rest = uri.substring(prefix.length);
  final q = rest.indexOf('?');
  final host = q < 0 ? rest : rest.substring(0, q);
  final query = q < 0 ? '' : rest.substring(q + 1).split('#').first;
  if (host != 'pair') throw const PairUriError('invalid_scheme');

  final params = <String, List<String>>{};
  if (query.isNotEmpty) {
    for (final part in query.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final k = Uri.decodeQueryComponent(eq < 0 ? part : part.substring(0, eq));
      final v = eq < 0 ? '' : Uri.decodeQueryComponent(part.substring(eq + 1));
      params.putIfAbsent(k, () => []).add(v);
    }
  }
  String? one(String k) => params[k]?.first;

  if (one('v') != '1') throw const PairUriError('unsupported_version');
  final sid = one('sid');
  if (sid == null || sid.isEmpty) throw const PairUriError('missing_server_id');
  final code = one('code');
  if (code == null || !_codeRe.hasMatch(code)) {
    throw const PairUriError('invalid_code');
  }
  final fp = one('fp');
  if (fp == null || fp.isEmpty) throw const PairUriError('missing_fingerprint');
  final us = params['u'] ?? const [];
  if (us.isEmpty) throw const PairUriError('missing_endpoint');
  if (!us.every((u) => u.startsWith('https://'))) {
    throw const PairUriError('insecure_endpoint');
  }
  final endpoints = <String>[];
  for (final u in us) {
    if (!endpoints.contains(u)) endpoints.add(u);
  }
  return PairUri(
      serverId: sid, code: code, fingerprint: fp, endpoints: endpoints);
}

/// Pinning rule (P§6.3): accept a system-trusted chain, otherwise the leaf
/// SPKI SHA-256 (unpadded base64url) must equal the pinned fingerprint.
bool acceptConnection(PairUri u,
    {required bool systemTrusted, required String spkiSha256}) {
  if (systemTrusted) return true;
  return spkiSha256.replaceAll('=', '') == u.fingerprint.replaceAll('=', '');
}
