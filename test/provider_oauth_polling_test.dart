import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

void main() {
  testWidgets(
    'provider OAuth keeps one poll in flight across timer callbacks',
    (tester) async {
      var calls = 0;
      final firstPoll = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(
        _app(
          ProviderOAuthLoginScreen(
            providerName: 'Provider',
            providerSlug: 'provider',
            url: 'https://idp.example/authorize',
            expiresIn: 60,
            launchBrowser: (_) async => false,
            pollDelays: const [Duration(seconds: 1), Duration(seconds: 1)],
            poll: () {
              calls++;
              return firstPoll.future;
            },
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 3));
      expect(calls, 1);

      firstPoll.complete({'status': 'pending'});
      await tester.pump();
    },
  );

  testWidgets(
    'provider OAuth pauses off-foreground and rechecks once on resume',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _app(
          ProviderOAuthLoginScreen(
            providerName: 'Provider',
            providerSlug: 'provider',
            url: 'https://idp.example/authorize',
            expiresIn: 60,
            launchBrowser: (_) async => false,
            pollDelays: const [Duration(seconds: 1)],
            poll: () async {
              calls++;
              return {'status': 'pending'};
            },
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(calls, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 9));
      expect(calls, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 1));
      expect(calls, 2);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
    },
  );
}
