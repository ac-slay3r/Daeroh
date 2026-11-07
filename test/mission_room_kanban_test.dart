import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('tracked create version gate matches the audited Hermes releases', () {
    expect(supportsKanbanTrackedCreateVersion('0.13.0'), isTrue);
    expect(supportsKanbanTrackedCreateVersion('hermes-agent 0.20.0'), isTrue);
    expect(supportsKanbanTrackedCreateVersion('0.12.0'), isFalse);
    expect(supportsKanbanTrackedCreateVersion('unknown'), isFalse);
    expect(supportsKanbanTrackedCreateVersion('v2026.5.7'), isTrue);
    expect(supportsKanbanTrackedCreateVersion('v2026.4.30'), isFalse);
  });

  test(
    'tracked create capability is read-only and direct evidence wins',
    () async {
      const connectionId = 'room-capability';
      var requests = 0;
      Future<bool> supports(CapabilityMatrix matrix) async {
        SharedPreferences.setMockInitialValues({
          'capabilities_$connectionId': jsonEncode(matrix.toJson()),
        });
        final dashboard = DashboardClient(
          host: '127.0.0.1',
          manualToken: 'session-token',
          httpClientOverride: MockClient((_) async {
            requests++;
            return http.Response('{}', 500);
          }),
        );
        final client = KanbanClient(
          SavedConnection(
            id: connectionId,
            label: 'Room QA',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'gateway-key',
          ),
          dashboardClient: dashboard,
        );
        final result = await client.supportsIdempotentTrackedCreate();
        client.close();
        return result;
      }

      expect(
        await supports(const CapabilityMatrix(gatewayVersion: '0.13.0')),
        isTrue,
      );
      expect(
        await supports(
          const CapabilityMatrix(
            gatewayVersion: '0.12.0',
            kanbanTrackedCreate: CapState.yes,
            serverSourced: ['kanbanTrackedCreate'],
          ),
        ),
        isTrue,
      );
      expect(
        await supports(
          const CapabilityMatrix(
            gatewayVersion: '0.20.0',
            kanbanTrackedCreate: CapState.no,
            serverSourced: ['kanbanTrackedCreate'],
          ),
        ),
        isFalse,
      );
      expect(requests, 0);
    },
  );

  test(
    'tracked create resolves the authoritative current board slug',
    () async {
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        manualToken: 'session-token',
        httpClientOverride: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'current': 'homelab',
              'boards': [
                {'slug': 'personal', 'name': 'Personal'},
                {'slug': 'homelab', 'name': 'Homelab', 'is_current': true},
              ],
            }),
            200,
          ),
        ),
      );
      final client = KanbanClient(
        SavedConnection(
          id: 'room-board-target',
          label: 'Room QA',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
        ),
        dashboardClient: dashboard,
      );
      addTearDown(client.close);

      final target = await client.resolveCurrentTaskTarget();

      expect(target.boardId, 'homelab');
      expect(target.boardQuery, 'homelab');
      expect(target.displayName, 'Homelab');
    },
  );

  test('current board snapshot is pinned to its authoritative slug', () async {
    final requests = <Uri>[];
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/boards')) {
          return http.Response(
            jsonEncode({
              'current': 'homelab',
              'boards': [
                {'slug': 'personal', 'name': 'Personal'},
                {'slug': 'homelab', 'name': 'Homelab', 'is_current': true},
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'columns': [
              {'name': 'running', 'tasks': const []},
            ],
            'latest_event_id': 7,
          }),
          200,
        );
      }),
    );
    final client = KanbanClient(
      SavedConnection(
        id: 'room-current-board',
        label: 'Room QA',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
      ),
      dashboardClient: dashboard,
    );
    addTearDown(client.close);

    final board = await client.getCurrentBoard();

    expect(board.boardId, 'homelab');
    expect(board.latestEventId, 7);
    expect(requests, hasLength(2));
    expect(requests.first.path, '/api/plugins/kanban/boards');
    expect(requests.last.path, '/api/plugins/kanban/board');
    expect(requests.last.queryParameters, {'board': 'homelab'});
  });

  test('legacy current board keeps the compatibility locator', () async {
    final requests = <Uri>[];
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/boards')) {
          return http.Response('{}', 404);
        }
        return http.Response(jsonEncode({'columns': const []}), 200);
      }),
    );
    final client = KanbanClient(
      SavedConnection(
        id: 'room-legacy-board',
        label: 'Room QA',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
      ),
      dashboardClient: dashboard,
    );
    addTearDown(client.close);

    final board = await client.getCurrentBoard();

    expect(board.boardId, 'legacy-current');
    expect(requests, hasLength(2));
    expect(requests.last.path, '/api/plugins/kanban/board');
    expect(requests.last.query, isEmpty);
  });

  test('200 board catalog without a valid board fails closed', () async {
    var posts = 0;
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'POST') posts++;
        return http.Response(
          jsonEncode({'current': 'missing', 'boards': []}),
          200,
        );
      }),
    );
    final client = KanbanClient(
      SavedConnection(
        id: 'room-empty-board-catalog',
        label: 'Room QA',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
      ),
      dashboardClient: dashboard,
    );
    addTearDown(client.close);

    await expectLater(client.resolveCurrentTaskTarget(), throwsStateError);
    expect(posts, 0);
  });

  test('current board outside the advertised catalog fails closed', () async {
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'session-token',
      httpClientOverride: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'current': 'deleted-board',
            'boards': [
              {'slug': 'homelab', 'name': 'Homelab'},
            ],
          }),
          200,
        ),
      ),
    );
    final client = KanbanClient(
      SavedConnection(
        id: 'room-invalid-current-board',
        label: 'Room QA',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
      ),
      dashboardClient: dashboard,
    );
    addTearDown(client.close);

    await expectLater(client.resolveCurrentTaskTarget(), throwsStateError);
  });

  test(
    'createTaskTracked sends idempotency key and returns real task id',
    () async {
      late http.Request captured;
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        manualToken: 'session-token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode({'columns': const []}), 200);
          }
          captured = request;
          return http.Response(
            jsonEncode({
              'task': {
                'id': 'task-real-42',
                'title': 'Revisar backups',
                'body': '@infra revisa los backups',
                'status': 'ready',
                'assignee': 'infra',
                'idempotency_key': 'room:r1:mention:i1:infra',
              },
            }),
            200,
          );
        }),
      );
      final client = KanbanClient(
        SavedConnection(
          id: 'room-kanban',
          label: 'Room QA',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
        ),
        dashboardClient: dashboard,
      );
      addTearDown(client.close);

      final task = await client.createTaskTracked(
        title: 'Revisar backups',
        body: '@infra revisa los backups',
        assignee: 'infra',
        idempotencyKey: 'room:r1:mention:i1:infra',
      );

      expect(task.id, 'task-real-42');
      expect(task.assignee, 'infra');
      expect(task.idempotencyKey, 'room:r1:mention:i1:infra');
      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/plugins/kanban/tasks');
      expect(jsonDecode(captured.body), {
        'title': 'Revisar backups',
        'body': '@infra revisa los backups',
        'assignee': 'infra',
        'idempotency_key': 'room:r1:mention:i1:infra',
      });
    },
  );

  test(
    'createTaskTracked rejects response without authoritative task id',
    () async {
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        manualToken: 'session-token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode({'columns': const []}), 200);
          }
          return http.Response(
            '{"task":{"title":"missing id",'
            '"idempotency_key":"room:r1:mention:i2:infra"}}',
            200,
          );
        }),
      );
      final client = KanbanClient(
        SavedConnection(
          id: 'room-kanban',
          label: 'Room QA',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
        ),
        dashboardClient: dashboard,
      );
      addTearDown(client.close);

      await expectLater(
        client.createTaskTracked(
          title: 'Missing id',
          idempotencyKey: 'room:r1:mention:i2:infra',
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('tracked create reconciles an existing key before any POST', () async {
    var postCalls = 0;
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'session-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'POST') postCalls++;
        return http.Response(
          jsonEncode({
            'columns': [
              {
                'name': 'ready',
                'tasks': [
                  {
                    'id': 'task-existing',
                    'title': 'Revisar backups',
                    'body': '@infra revisa los backups',
                    'status': 'ready',
                    'assignee': 'infra',
                    'idempotency_key': 'room:r1:mention:i1:infra',
                  },
                ],
              },
            ],
          }),
          200,
        );
      }),
    );
    final client = KanbanClient(
      SavedConnection(
        id: 'room-reconcile',
        label: 'Room QA',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
      ),
      dashboardClient: dashboard,
    );
    addTearDown(client.close);

    final task = await client.createTaskTracked(
      title: 'Revisar backups',
      body: '@infra revisa los backups',
      assignee: 'infra',
      idempotencyKey: 'room:r1:mention:i1:infra',
    );

    expect(task.id, 'task-existing');
    expect(postCalls, 0);
  });

  test(
    'authoritative roster never turns schema failure into empty success',
    () async {
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        manualToken: 'session-token',
        httpClientOverride: MockClient(
          (_) async => http.Response('{"unexpected":[]}', 200),
        ),
      );
      final client = KanbanClient(
        SavedConnection(
          id: 'room-roster',
          label: 'Room QA',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
        ),
        dashboardClient: dashboard,
      );
      addTearDown(client.close);

      await expectLater(
        client.getProfilesAuthoritative(),
        throwsA(isA<StateError>()),
      );
    },
  );
}
