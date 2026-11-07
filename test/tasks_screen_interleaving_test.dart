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

http.Response board(String title) => http.Response(
  jsonEncode({
    'columns': [
      {
        'name': 'todo',
        'tasks': [
          {'id': title, 'title': title, 'status': 'todo'},
        ],
      },
    ],
  }),
  200,
);

void main() {
  for (final silent in [false, true]) {
    for (final filterChange in [false, true]) {
      for (final fails in [false, true]) {
        for (final staleFirst in [false, true]) {
          testWidgets(
            'request fence silent=$silent filter=$filterChange failure=$fails staleFirst=$staleFirst',
            (tester) async {
              tester.view.physicalSize = const Size(900, 1600);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              final events = StreamController<KanbanEvent>.broadcast();
              addTearDown(events.close);
              final stale = Completer<http.Response>();
              final current = Completer<http.Response>();
              final reads = <Uri>[];
              final transport = MockClient((request) async {
                if (request.url.path.endsWith('/board')) {
                  reads.add(request.url);
                  return switch (reads.length) {
                    1 => board('initial'),
                    2 => stale.future,
                    3 => current.future,
                    _ => throw StateError('Unexpected extra board request'),
                  };
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
                  return http.Response('{"profiles":[]}', 200);
                }
                return http.Response('{}', 404);
              });
              final connection = SavedConnection(
                id: 'interleaving',
                label: 'QA',
                host: '127.0.0.1',
                port: 8642,
                apiKey: '',
                useHttps: true,
              );
              final dashboard = DashboardClient(
                host: '127.0.0.1',
                manualToken: 'test-token',
                httpClientOverride: transport,
              );
              await tester.pumpWidget(
                MaterialApp(
                  locale: const Locale('en'),
                  localizationsDelegates: Strings.localizationsDelegates,
                  supportedLocales: Strings.supportedLocales,
                  theme: AppTheme.fromId('dark'),
                  home: TasksScreen(
                    connection: connection,
                    initialBoard: 'a',
                    clientOverride: KanbanClient(
                      connection,
                      dashboardClient: dashboard,
                    ),
                    eventStreamOverride: events.stream,
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final refresh = find.byTooltip(
                Strings.of(
                  tester.element(find.byType(TasksScreen)),
                ).kanbanRefresh,
              );
              if (silent) {
                events.add(
                  KanbanEvent.fromJson({'id': 1, 'type': 'task.updated'}),
                );
              } else {
                await tester.tap(refresh);
              }
              await tester.pump(const Duration(milliseconds: 500));
              expect(reads.length, 2);
              if (filterChange) {
                await tester.tap(
                  find.byKey(const ValueKey('kanban-filter-button')),
                );
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 300));
                await tester.enterText(
                  find.byKey(const ValueKey('kanban-search-field')),
                  'new',
                );
                await tester.pump();
                await tester.tapAt(const Offset(850, 800));
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 300));
                // Local filters invalidate a silent request without fetching.
                // Explicit loads restart immediately so loading can finish.
                if (silent) {
                  expect(reads.length, 2);
                  await tester.tap(refresh);
                  await tester.pump();
                }
              } else {
                await tester.tap(
                  find.byKey(const ValueKey('kanban-board-selector')),
                );
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 300));
                await tester.tap(find.text('Board B').last);
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 300));
              }
              expect(reads.length, 3);
              expect(reads[1].queryParameters['board'], 'a');
              expect(
                reads[2].queryParameters['board'],
                filterChange ? 'a' : 'b',
              );
              void finishStale() => stale.complete(
                fails
                    ? http.Response('obsolete failure', 500)
                    : board('new obsolete'),
              );
              if (staleFirst) {
                finishStale();
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 100));
                expect(find.byType(CircularProgressIndicator), findsOneWidget);
                expect(find.textContaining('obsolete failure'), findsNothing);
                expect(
                  find.byKey(const ValueKey('kanban-task-new obsolete')),
                  findsNothing,
                );
                // Background activity cannot steal the explicit load's generation.
                events.add(
                  KanbanEvent.fromJson({'id': 2, 'type': 'task.updated'}),
                );
                await tester.pump(const Duration(milliseconds: 500));
                expect(reads.length, 3);
              }
              current.complete(board('new current'));
              await tester.pumpAndSettle();
              expect(
                find.byKey(const ValueKey('kanban-task-new current')),
                findsOneWidget,
              );
              if (!staleFirst) {
                finishStale();
                await tester.pumpAndSettle();
              }
              expect(
                find.byKey(const ValueKey('kanban-task-new current')),
                findsOneWidget,
              );
              expect(
                find.byKey(const ValueKey('kanban-task-new obsolete')),
                findsNothing,
              );
              expect(find.textContaining('obsolete failure'), findsNothing);
              expect(find.byType(CircularProgressIndicator), findsNothing);
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox.shrink());
            },
          );
        }
      }
    }
  }
}
