/// Pure decision function for the non-backup flows (browse, pairing, setup,
/// auth). Mirrors sync-protocol.md §8 (problem catalogue), §9 (R5, R7, R11)
/// and §10.5 (action table and attempt counting). No I/O, no clock.
library;

/// What the client knew before the request that produced [ServerOutcome].
class Given {
  const Given({
    required this.flow,
    this.itemState = '',
    required this.lastAction,
    this.item = const {},
  });

  /// One of browse, pairing, setup, auth (backup and free_up_space belong to
  /// the native engines).
  final String flow;
  final String itemState;
  final String lastAction;
  final Map<String, Object?> item;
}

/// A response, or a transport failure (timeout, reset, offline).
class ServerOutcome {
  const ServerOutcome({
    this.status,
    this.headers = const {},
    this.body,
    this.transport,
  });

  final int? status;
  final Map<String, String> headers;
  final Object? body;

  /// timeout | reset | offline
  final String? transport;
}

class Decision {
  const Decision(this.nextState, this.action, this.attemptsDelta);

  final String nextState;
  final String action;
  final int attemptsDelta;

  @override
  String toString() => 'Decision($nextState, $action, $attemptsDelta)';
}

/// Expands `server.problem: "<code>"` to the problem body of P§10.5.
Map<String, Object?> problemBody(String code, int status) => {
      'type': 'urn:pictunnel:problem:$code',
      'title': code,
      'status': status,
      'code': code,
    };

String? _problemCode(Object? body) {
  if (body is Map) {
    final c = body['code'];
    if (c is String) return c;
  }
  return null;
}

Decision decide(Given g, ServerOutcome s) {
  final state = g.itemState;
  Decision d(String action, [int attempts = 0, String? next]) =>
      Decision(next ?? state, action, attempts);

  final transport = s.transport;
  if (transport != null) {
    if (transport == 'offline') return d('wait_for_network'); // R5: no attempt
    return d('backoff_retry', 1); // timeout, reset
  }

  final status = s.status ?? 0;
  if (status >= 200 && status < 300) {
    return g.flow == 'auth' && g.lastAction == 'refresh'
        ? d('retry_original_request')
        : d('continue');
  }

  switch (_problemCode(s.body)) {
    case 'refresh_token_reused':
      return d('require_repair', 0, 'Paused');
    case 'token_expired':
      return g.lastAction == 'refresh'
          ? d('require_repair', 0, 'Paused')
          : d('refresh_then_retry');
    case 'unauthorized':
      // Refresh once, then re-login (§8).
      return g.lastAction == 'refresh'
          ? d('require_repair', 0, 'Paused')
          : d('refresh_then_retry');
    case 'cursor_expired':
    case 'cursor_required':
      return d('run_snapshot');
    case 'not_ready':
      return d('retry_later');
    case 'pairing_code_invalid':
    case 'forbidden':
    case 'invalid_request':
      return d('show_error');
    case 'setup_already_done':
      return d('go_to_login');
    case 'client_too_old':
      return d('prompt_update');
    case 'rate_limited':
      return d('wait_retry_after'); // does not count
    case 'server_unavailable':
      return d('wait_retry_after', 1); // counts
    case 'internal':
      return d('backoff_retry', 1);
  }

  // R7: unknown 4xx are non-retryable, unknown 5xx retryable.
  if (status >= 500) return d('backoff_retry', 1);
  if (status >= 400) return d('show_error');
  return d('skip_this_run');
}
