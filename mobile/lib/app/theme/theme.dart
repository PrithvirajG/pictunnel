import 'package:flutter/material.dart';

import 'tokens.dart';
import 'typography.dart';

ThemeData darkroomTheme() {
  const scheme = ColorScheme.dark(
    surface: Tokens.surface,
    onSurface: Tokens.text,
    primary: Tokens.accent,
    onPrimary: Tokens.ground,
    secondary: Tokens.ok,
    outline: Tokens.line,
    onSurfaceVariant: Tokens.muted,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Tokens.ground,
    canvasColor: Tokens.ground,
    dividerColor: Tokens.line,
    fontFamily: bodyFamily,
    textTheme: TextTheme(
      headlineMedium: displayStyle(),
      titleLarge: displayStyle(size: 22),
      bodyLarge: bodyStyle(size: 16),
      bodyMedium: bodyStyle(),
      labelSmall: bodyStyle(size: 12, color: Tokens.muted),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Tokens.ground,
      foregroundColor: Tokens.text,
      elevation: 0,
      titleTextStyle: displayStyle(),
    ),
  );
}
