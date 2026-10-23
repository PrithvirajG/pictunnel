import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../backup/backup_providers.dart';

final _stamp = DateFormat('MMM d, HH:mm');

class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(activityProvider);
    return Scaffold(
      appBar: AppBar(title: Text('Activity', style: displayStyle(size: 20))),
      body: entries.when(
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Text(
                'No activity yet.',
                key: const Key('activityEmpty'),
                style: bodyStyle(size: 15, color: Tokens.muted),
              ),
            );
          }
          final sorted = [...list]..sort((a, b) => b.atMs.compareTo(a.atMs));
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              for (final e in sorted)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF222222)),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.message, style: bodyStyle(size: 15)),
                      const SizedBox(height: 2),
                      Text(
                        _stamp.format(
                          DateTime.fromMillisecondsSinceEpoch(e.atMs),
                        ),
                        style: bodyStyle(size: 13, color: Tokens.muted),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
