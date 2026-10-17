import 'package:flutter/painting.dart';

import 'tokens.dart';

const displayFamily = 'Bricolage Grotesque';
const bodyFamily = 'Figtree';

FontWeight _weight(int w) => FontWeight.values[(w ~/ 100) - 1];

TextStyle displayStyle({
  double size = 28,
  int weight = 700,
  Color color = Tokens.text,
}) => TextStyle(
  fontFamily: displayFamily,
  fontSize: size,
  fontWeight: _weight(weight),
  fontVariations: [FontVariation('wght', weight.toDouble())],
  color: color,
  height: 1.15,
);

TextStyle bodyStyle({
  double size = 14,
  int weight = 400,
  Color color = Tokens.text,
}) => TextStyle(
  fontFamily: bodyFamily,
  fontSize: size,
  fontWeight: _weight(weight),
  fontVariations: [FontVariation('wght', weight.toDouble())],
  color: color,
);
