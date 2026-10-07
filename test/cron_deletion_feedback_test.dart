import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('deleted=false conserva el cron y muestra rechazo localizado', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/cron/jobs') {
          return http.Response(
            jsonEncode([
              {
                'id': 'demo-daily-summary',
                'name': 'Daily demo summary',
                'schedule': '0 9 * * *',
                'prompt': 'Summarize the day',
                'enabled': true,
              },
            ]),
            200,
          );
        }
        if (request.method == 'DELETE') {
          return http.Response(jsonEncode({'deleted': false}), 200);
        }
        return http.Response('not found', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: CronScreen(
          connection: SavedConnection(
            id: 'demo',
            label: 'Demo',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'gateway-key',
            useHttps: true,
          ),
          clientOverride: client,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Daily demo summary'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('cron-job-menu-demo-daily-summary')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(find.text('Daily demo summary'), findsOneWidget);
    expect(
      find.text(
        'The server kept this protected scheduled task. Nothing was deleted.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Exception:'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
