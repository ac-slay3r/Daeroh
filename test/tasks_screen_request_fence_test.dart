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
  final connection = SavedConnection(
    id: 'request-fence',
    label: 'QA',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'test-key',
    useHttps: true,
  );

  http.Response board(String id, {String status = 'todo'}) => http.Response(
    jsonEncode({
      'columns': [
        {
          'name': status,
          'tasks': [
            {'id': id, 'title': id, 'status': status},
          ],
        },
      ],
    }),
    200,
  );

  Future<void> mount(
    WidgetTester tester,
    MockClient httpClient,
    Stream<KanbanEvent> events,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
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
          eventStreamOverride: events,
          initialBoard: 'a',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('late explicit board A success cannot replace selected board B', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    final lateA = Completer<http.Response>();
    var aReads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/board')) {
        if (request.url.queryParameters['board'] == 'a') {
          if (++aReads == 2) return lateA.future;
          return board('initial-a');
        }
        return board('current-b');
      }
      if (request.url.path.endsWith('/boards')) {
        return http.Response(
          jsonEncode({
            'current': 'a',
            'boards': [
              {'slug': 'a', 'name': 'Board A'},
              {'slug': 'b', 'name': 'Board B'},
            ],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/profiles')) {
        return http.Response(jsonEncode({'profiles': []}), 200);
      }
      return http.Response('{}', 404);
    });
    await mount(tester, client, events.stream);
    await tester.tap(
      find.byTooltip(
        Strings.of(tester.element(find.byType(TasksScreen))).kanbanRefresh,
      ),
    );
    await tester.pump();
    expect(aReads, 2);
    await tester.tap(find.byKey(const ValueKey('kanban-board-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Board B').last);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('kanban-task-current-b')), findsOneWidget);
    lateA.complete(board('obsolete-a'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kanban-task-current-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-task-obsolete-a')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late archived filter error cannot clear newer search results', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    final archived = Completer<http.Response>();
    var archivedReads = 0;
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.path.endsWith('/board')) {
        if (request.url.queryParameters['include_archived'] == 'true') {
          if (++archivedReads == 1) return archived.future;
          return board('new archived', status: 'archived');
        }
        return board('initial');
      }
      if (request.url.path.endsWith('/boards')) return http.Response('{}', 404);
      if (request.url.path.endsWith('/profiles')) {
        return http.Response(jsonEncode({'profiles': []}), 200);
      }
      return http.Response('{}', 404);
    });
    await mount(tester, client, events.stream);
    await tester.tap(find.byKey(const ValueKey('kanban-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kanban-filter-archived')));
    // Finish dismissing the old route before trying to reopen the filter.
    // Do not pumpAndSettle: the first archived load is intentionally pending.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('kanban-search-field')), findsNothing);
    expect(archivedReads, 1);
    expect(archived.isCompleted, isFalse);
    await tester.tap(find.byKey(const ValueKey('kanban-filter-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('kanban-search-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('kanban-search-field')),
      'new',
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(archivedReads, 2, reason: '$requests');
    expect(archived.isCompleted, isFalse);
    await tester.tapAt(const Offset(850, 800));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('kanban-task-new archived')),
      findsOneWidget,
    );
    archived.complete(http.Response('late archived failure', 500));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('kanban-task-new archived')),
      findsOneWidget,
    );
    expect(find.textContaining('late archived failure'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late silent board A refresh cannot replace board B', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<KanbanEvent>.broadcast();
    addTearDown(events.close);
    final lateA = Completer<http.Response>();
    var aReads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/board')) {
        if (request.url.queryParameters['board'] == 'a') {
          if (++aReads == 2) return lateA.future;
          return board('initial-a');
        }
        return board('current-b');
      }
      if (request.url.path.endsWith('/boards')) {
        return http.Response(
          jsonEncode({
            'current': 'a',
            'boards': [
              {'slug': 'a', 'name': 'Board A'},
              {'slug': 'b', 'name': 'Board B'},
            ],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/profiles')) {
        return http.Response(jsonEncode({'profiles': []}), 200);
      }
      return http.Response('{}', 404);
    });
    await mount(tester, client, events.stream);
    events.add(KanbanEvent.fromJson({'id': 1, 'type': 'task.updated'}));
    await tester.pump(const Duration(milliseconds: 500));
    expect(aReads, 2);
    await tester.tap(find.byKey(const ValueKey('kanban-board-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Board B').last);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('kanban-task-current-b')), findsOneWidget);
    lateA.complete(board('obsolete-a'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kanban-task-current-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-task-obsolete-a')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
