import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/models/companion_presence_level.dart';
import 'package:hermes_android/core/companion/render/companion_empty_state_presence.dart';
import 'package:hermes_android/core/companion/render/spritesheet_renderer.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/widgets/hermes_spark_mascot.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo extends CompanionRepository {
  @override
  Future<List<Companion>> loadAll() async => [
    Companion(
      slug: 'nimbus',
      name: 'Nimbus',
      author: 'team',
      license: 'CC0-1.0',
      spritesheetAsset: 'assets/companions/nimbus/spritesheet.webp',
      frameWidth: 192,
      frameHeight: 208,
      cols: 8,
      rows: 9,
      fps: 8,
      states: const {
        CompanionAnimationState.idle: RowSpec(
          row: 0,
          frameCount: 8,
          loop: true,
        ),
      },
    ),
  ];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Home empty state shows selected pet and obeys Home visibility', (
    tester,
  ) async {
    final controller = CompanionController(
      _Repo(),
      await CompanionPreferences.load(),
    );
    await controller.init();
    await controller.select('nimbus');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompanionEmptyStatePresence(
            controller: controller,
            onHome: true,
          ),
        ),
      ),
    );
    expect(find.byType(SpritesheetRenderer), findsOneWidget);
    expect(find.byType(HermesSparkMascot), findsNothing);

    await controller.setShowOnHome(false);
    await tester.pump();
    expect(find.byType(SpritesheetRenderer), findsNothing);
    expect(find.byType(HermesSparkMascot), findsNothing);
  });

  testWidgets('Runs empty state only shows the chosen pet with full presence', (
    tester,
  ) async {
    final controller = CompanionController(
      _Repo(),
      await CompanionPreferences.load(),
    );
    await controller.init();
    await controller.select('nimbus');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompanionEmptyStatePresence(
            controller: controller,
            onHome: false,
          ),
        ),
      ),
    );
    expect(find.byType(SpritesheetRenderer), findsNothing);
    await controller.setPresenceLevel(CompanionPresenceLevel.full);
    await tester.pump();
    expect(find.byType(SpritesheetRenderer), findsOneWidget);
  });
}
