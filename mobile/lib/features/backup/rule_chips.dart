import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';

List<String> ruleLabels(EngineSettings s) => [
  s.wifiOnly ? 'Wi-Fi only' : 'Wi-Fi or mobile data',
  s.includeVideos ? 'Videos included' : 'Photos only',
  s.chargingOnly ? 'Only while charging' : 'Any battery level',
];

class RuleChips extends StatelessWidget {
  const RuleChips({super.key, required this.settings});

  final EngineSettings settings;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final label in ruleLabels(settings))
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            decoration: BoxDecoration(
              color: Tokens.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2E2E2E)),
            ),
            child: Text(label, style: bodyStyle(size: 13)),
          ),
      ],
    );
  }
}
