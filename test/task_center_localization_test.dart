import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/task_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final language in ['en', 'es']) {
    for (final systemLocale in [false, true]) {
      testWidgets(
        'Task Center title follows $language (system: $systemLocale)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.binding.platformDispatcher.localesTestValue = [
            Locale(language),
          ];
          addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

          await tester.pumpWidget(
            MaterialApp(
              locale: systemLocale ? null : Locale(language),
              localizationsDelegates: Strings.localizationsDelegates,
              supportedLocales: Strings.supportedLocales,
              theme: AppTheme.fromId('dark'),
              home: TaskCenterScreen(
                connection: SavedConnection(
                  id: 'task-center-localization',
                  label: 'Localization test',
                  host: '127.0.0.1',
                  port: 8642,
                  apiKey: '',
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final strings = Strings.of(
            tester.element(find.byType(TaskCenterScreen)),
          );
          final appBar = tester.widget<HermesAppBar>(find.byType(HermesAppBar));
          expect(
            (appBar.title as Text).data,
            language == 'en' ? 'TASK CENTER' : 'EJECUCIONES',
          );
          expect(
            (appBar.title as Text).data,
            strings.drawerTaskCenter.toUpperCase(),
          );
          expect(find.text(strings.runsEmpty), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
