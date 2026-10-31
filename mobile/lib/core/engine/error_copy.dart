/// User-facing copy for engine errors (`PlatformException.code`) and for the
/// reasons free up space keeps an item (spec M§8: one table per platform,
/// keyed by code).
library;

import 'package:flutter/services.dart' show PlatformException;

const engineErrorCopy = <String, String>{
  'not_paired': 'This phone is not paired with a server. Pair it first.',
  'needs_repair':
      'Your server no longer recognises this phone. Pair it again to continue.',
  'no_activity': 'Open PicTunnel and try again.',
  'not_found': 'That item is no longer on this phone.',
  'permission':
      'PicTunnel needs access to your photos for this. Allow it in Settings.',
  'unreachable':
      "Can't reach your server. Check that your phone is on the same network, or that the server is online.",
  'offline': "You're offline. Connect to a network and try again.",
  'timeout': 'Your server took too long to answer. Try again.',
  'tls':
      "This server's security certificate has changed. Pair again if you reinstalled PicTunnel on your computer.",
  'client_too_old':
      'This version of PicTunnel is too old for your server. Update the app.',
  'rate_limited': 'Too many attempts. Wait a minute and try again.',
  'bad_response': 'Your server sent an answer PicTunnel did not understand.',
  'invalid_request': "The server couldn't accept that request.",
  'undo_failed': 'The server did not confirm. Try again.',
  'insufficient_storage': 'Your server is out of space.',
  'quota_exceeded': 'Your storage limit on the server is reached.',
  'forbidden': "This account isn't allowed to do that.",
  'unauthorized': 'Your server no longer accepts this phone. Pair it again.',
};

const genericErrorCopy = 'Something went wrong. Try again.';

/// Copy for an `http_<status>` code the server answered without a problem body.
String httpStatusCopy(int status) {
  if (status >= 500) {
    return 'Your server had a problem (error $status). Try again later.';
  }
  return 'Your server refused the request (error $status).';
}

/// Copy for an engine error [code], or null when there is none.
String? engineCodeCopy(String code) {
  final direct = engineErrorCopy[code];
  if (direct != null) return direct;
  final m = RegExp(r'^http_(\d{3})$').firstMatch(code);
  return m == null ? null : httpStatusCopy(int.parse(m[1]!));
}

/// Copy for any error thrown by an engine call.
String engineErrorMessage(Object error) {
  final code = error is PlatformException ? error.code : null;
  return (code == null ? null : engineCodeCopy(code)) ?? genericErrorCopy;
}

/// Why free up space kept an item on the phone (SkippedFree.reason).
const freeUpSkipCopy = <String, String>{
  'cancelled': 'You chose to keep them',
  'not_backed_up': 'Not backed up yet',
  'fingerprint_changed': 'Changed since the backup',
  'not_active_on_server': 'In the server trash',
  'not_on_server_disk': 'Not confirmed on the server disk',
  'server_missing': 'Not found on the server',
  'check_failed': "The server couldn't confirm them",
  'denied': "The server couldn't confirm them",
  'unknown': 'No longer on this phone',
  'not_found': 'No longer on this phone',
};

String freeUpSkipReason(String reason) =>
    freeUpSkipCopy[reason] ??
    (reason.startsWith('server_')
        ? 'Not confirmed on the server'
        : engineCodeCopy(reason) ?? "The server couldn't confirm them");
