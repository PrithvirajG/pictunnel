/// File names built from server data (filenames, asset ids) that can never
/// leave the directory they are joined to.
library;

import 'dart:convert';

const _maxNameLength = 120;

/// The last path segment of [name], without characters that file systems
/// reject or treat specially, and never `.`/`..` or a hidden name. Falls
/// back to [fallback] when nothing usable is left. At most 120 characters,
/// keeping a short extension.
String sanitizeFileName(String name, {String fallback = 'file'}) {
  var base = name.split(RegExp(r'[/\\]')).last;
  base = base.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_').trim();
  base = base.replaceFirst(RegExp(r'^\.+'), '');
  if (base.isEmpty) base = fallback;
  if (base.length > _maxNameLength) {
    final dot = base.lastIndexOf('.');
    final ext = dot > 0 && base.length - dot <= 10 ? base.substring(dot) : '';
    base = base.substring(0, _maxNameLength - ext.length) + ext;
  }
  return base;
}

/// [value] as one file-name component: ASCII letters, digits, `-` and `_`
/// stay; every other byte becomes `.XX` (hex). Injective, so two ids never
/// share a file, and free of separators and `..`.
String safeFileComponent(String value) {
  final out = StringBuffer();
  for (final b in utf8.encode(value)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9_-]').hasMatch(c)) {
      out.write(c);
    } else {
      out.write('.${b.toRadixString(16).padLeft(2, '0')}');
    }
  }
  return out.isEmpty ? '.' : out.toString();
}
