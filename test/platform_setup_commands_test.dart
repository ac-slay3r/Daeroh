import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/platform_setup_commands.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets('offers Linux pairing and labels other hosts unsupported', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(body: PlatformSetupCommands(pairing: true)),
      ),
    );
    expect(find.textContaining('Linux'), findsOneWidget);
    expect(
      find.textContaining('macOS and Windows server pairing are not supported'),
      findsOneWidget,
    );
  });
}
