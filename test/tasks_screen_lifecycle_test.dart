import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('initial board load cannot subscribe while paused', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pendingBoard = Completer<http.Response>();
    var boardReads = 0;
    final httpClient = MockClient((request) async {
      if (request.url.path.endsWith('/board')) {
        boardReads++;
        if (boardReads == 1) return pendingBoard.future;
        return http.Response(jsonEncode({'columns': []}), 200);
      }
      if (request.url.path.endsWith('/boards')) {
        return http.Response('{}', 404);
      }
      if (request.url.path.endsWith('/profiles')) {
        return http.Response(jsonEncode({'profiles': []}), 200);
      }
      return http.Response('{}', 404);
    });
    final connection = SavedConnection(
      id: 'lifecycle-test',
      label: 'QA',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
      useHttps: true,
    );
    var activeSubscriptions = 0;
    var subscriptionStarts = 0;
    final events = StreamController<KanbanEvent>.broadcast(
      onListen: () {
        activeSubscriptions++;
        subscriptionStarts++;
      },
      onCancel: () => activeSubscriptions--,
    );
    addTearDown(events.close);
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'session-token',
      httpClientOverride: httpClient,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: TasksScreen(
          connection: connection,
          clientOverride: KanbanClient(connection, dashboardClient: dashboard),
          eventStreamOverride: events.stream,
        ),
      ),
    );
    expect(boardReads, 1);
    expect(activeSubscriptions, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    pendingBoard.complete(http.Response(jsonEncode({'columns': []}), 200));
    await tester.pumpAndSettle();
    expect(activeSubscriptions, 0);
    expect(subscriptionStarts, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(activeSubscriptions, 1);
    expect(subscriptionStarts, 1);
    expect(boardReads, 2);
    expect(tester.takeException(), isNull);

    events.add(KanbanEvent.fromJson({'id': 1, 'type': 'task.updated'}));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 5));
    expect(boardReads, 2, reason: 'queued refresh must not run in background');
    expect(activeSubscriptions, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(boardReads, 3);
    expect(activeSubscriptions, 1);
    expect(subscriptionStarts, 2);
    // Duplicate resume does not trigger another refresh or subscription.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(boardReads, 3);
    expect(subscriptionStarts, 2);
    events.add(KanbanEvent.fromJson({'id': 2, 'type': 'task.updated'}));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(boardReads, 3, reason: 'queued refresh must not run after dispose');
    expect(activeSubscriptions, 0);
  });
}
