import 'package:flutter/material.dart';

import 'library.dart';

class DownloadControls extends StatelessWidget {
  final DownloadTask task;
  const DownloadControls({super.key, required this.task});

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: task,
    builder: (context, _) {
      if (task.complete ||
          task.cancelled ||
          (!task.active && task.error == null)) {
        return const SizedBox.shrink();
      }
      final total = task.total;
      final progress = total != null && total > 0
          ? (task.received / total).clamp(0.0, 1.0)
          : null;
      final received = (task.received / 1048576).toStringAsFixed(1);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task.statusLabel),
          const SizedBox(height: 8),
          if (task.active)
            LinearProgressIndicator(
              value: task.paused ? (progress ?? 0) : progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(99),
              color: const Color(0xFFF2B86B),
              backgroundColor: const Color(0xFF2A343A),
              semanticsLabel: '${task.title.title} download progress',
            ),
          const SizedBox(height: 6),
          Text(
            total == null || total <= 0
                ? '$received MB'
                : '$received / ${(total / 1048576).toStringAsFixed(1)} MB',
          ),
          if (task.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(task.error!),
            ),
          Wrap(
            spacing: 8,
            children: [
              if (task.paused)
                TextButton.icon(
                  onPressed: () => _run(context, task.resume),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume download'),
                )
              else if (task.active)
                TextButton.icon(
                  onPressed: () => _run(context, task.pause),
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause download'),
                )
              else
                TextButton.icon(
                  onPressed: () => _run(context, task.retry),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry download'),
                ),
              TextButton.icon(
                onPressed: () => _run(context, task.cancel),
                icon: const Icon(Icons.close),
                label: const Text('Cancel download'),
              ),
            ],
          ),
        ],
      );
    },
  );
}
