import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/admin_integrations_copy.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  for (final locale in const [Locale('en'), Locale('es')]) {
    testWidgets('${locale.languageCode} integration copy uses ARB strings', (
      tester,
    ) async {
      late AdminIntegrationsCopy copy;
      late Strings strings;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Builder(
            builder: (context) {
              copy = AdminIntegrationsCopy.of(context);
              strings = Strings.of(context);
              return Text(copy.screenTitle);
            },
          ),
        ),
      );

      expect(find.text(strings.adminIntegrationScreenTitle), findsOneWidget);
      expect(copy.readOnly, strings.adminIntegrationReadOnly);
      expect(
        copy.a2aState('connecting'),
        strings.adminIntegrationA2aStateConnecting,
      );
      expect(copy.oauthTools(1), strings.adminIntegrationOauthTools(1));
      expect(copy.oauthTools(2), strings.adminIntegrationOauthTools(2));
      expect(
        copy.oauthTools(1),
        locale.languageCode == 'en'
            ? '1 tool available'
            : '1 herramienta disponible',
      );
      expect(
        copy.webhookSubtitle('log', const []),
        '${strings.adminIntegrationDeliveryLabelLog} · ${strings.adminIntegrationAllEvents}',
      );
    });
  }
}
