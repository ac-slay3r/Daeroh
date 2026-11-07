import 'package:flutter/material.dart';

import '../../widgets/hermes_spark_mascot.dart';
import '../models/companion_presence_level.dart';
import '../state/companion_controller.dart';
import 'companion_view.dart';

/// Empty-state presence follows the same selected pet and visibility controls
/// as the Home composer and Chat, rather than painting an unrelated Spark.
class CompanionEmptyStatePresence extends StatelessWidget {
  const CompanionEmptyStatePresence({
    super.key,
    required this.controller,
    required this.onHome,
  });

  final CompanionController controller;
  final bool onHome;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (!controller.isInitialized ||
          !controller.enabled ||
          (onHome
              ? !controller.showOnHome || !controller.presenceLevel.isVisible
              : !controller.presenceLevel.showsStatusPresence)) {
        return const SizedBox.shrink();
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CompanionView(
            controller: controller,
            mood: HermesSparkMood.idle,
            size: 48,
          ),
          SizedBox(height: onHome ? 14 : 12),
        ],
      );
    },
  );
}
