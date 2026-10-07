import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  SavedConnection connection() => SavedConnection(
    id: 'kanban-spec058',
    label: 'QA',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    useHttps: true,
  );

  test('legacy sin /boards conserva fallback de board activo', () async {
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        expect(request.url.path, '/api/plugins/kanban/boards');
        return http.Response('{}', 404);
      }),
    );
    final client = KanbanClient(connection(), dashboardClient: dashboard);
    addTearDown(client.close);

    expect(await client.getBoardsIfSupported(), isNull);
  });

  test(
    'board, detalle, archivo y delete usan contratos separados y acotados',
    () async {
      final requests = <http.Request>[];
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        manualToken: 'session-token',
        httpClientOverride: MockClient((request) async {
          requests.add(request);
          switch ((request.method, request.url.path)) {
            case ('GET', '/api/plugins/kanban/boards'):
              return http.Response(
                jsonEncode({
                  'current': 'project',
                  'boards': [
                    {'slug': 'default', 'name': 'Personal'},
                    {'slug': 'project', 'name': 'Project'},
                  ],
                }),
                200,
              );
            case ('GET', '/api/plugins/kanban/board'):
              return http.Response(
                jsonEncode({'columns': [], 'latest_event_id': 7}),
                200,
              );
            case ('GET', '/api/plugins/kanban/tasks/task%2Fone'):
              return http.Response(
                jsonEncode({
                  'task': {
                    'id': 'task/one',
                    'title': 'Hydrated',
                    'body': 'Full body from GET /tasks/:id',
                    'status': 'done',
                    'result': 'Complete result',
                  },
                }),
                200,
              );
            case ('PATCH', '/api/plugins/kanban/tasks/task-1'):
              return http.Response('{}', 200);
            case ('DELETE', '/api/plugins/kanban/tasks/task-1'):
              return http.Response('{}', 200);
            default:
              return http.Response('{}', 404);
          }
        }),
      );
      final client = KanbanClient(connection(), dashboardClient: dashboard);
      addTearDown(client.close);

      final catalog = await client.getBoardsIfSupported();
      expect(catalog?.current, 'project');

      await client.getBoard(includeArchived: true, board: 'project');
      final detail = await client.getTask('task/one', board: 'project');
      await client.archiveTask('task-1', board: 'project');
      await client.deleteTask('task-1', board: 'project');

      expect(detail.body, 'Full body from GET /tasks/:id');
      expect(detail.result, 'Complete result');

      final boardRequest = requests.firstWhere(
        (request) => request.url.path.endsWith('/board'),
      );
      expect(boardRequest.url.queryParameters, {
        'include_archived': 'true',
        'board': 'project',
      });
      final detailRequest = requests.firstWhere(
        (request) => request.url.path.contains('task%2Fone'),
      );
      expect(detailRequest.url.queryParameters['board'], 'project');

      final archive = requests.firstWhere(
        (request) => request.method == 'PATCH',
      );
      expect(jsonDecode(archive.body), {'status': 'archived'});
      final deletion = requests.firstWhere(
        (request) => request.method == 'DELETE',
      );
      expect(deletion.url.queryParameters['board'], 'project');
    },
  );
}
