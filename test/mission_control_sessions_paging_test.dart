import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';

Map<String, Object> row(int index, {String profile = 'default'}) => {
  'id': 'session-$index',
  'profile': profile,
};

void main() {
  for (final count in [201, 400, 401, 501, 601]) {
    test(
      'repository snapshot retains all $count advertised sessions',
      () async {
        final offsets = <int>[];
        final repository = MissionControlRepository(
          profilesLoader: () async => [],
          boardLoader: () async => const KanbanBoard(columns: []),
          sessionsLoader: () => loadMissionControlSessions(
            dashboardGet: (endpoint) async {
              final uri = Uri.parse(endpoint);
              final offset = int.parse(uri.queryParameters['offset']!);
              expect(uri.path, 'profiles/sessions');
              expect(uri.queryParameters, {
                'profile': 'all',
                'limit': '200',
                'offset': '$offset',
                'min_messages': '0',
                'archived': 'exclude',
                'order': 'recent',
                'full': '1',
                'include_children': 'true',
              });
              offsets.add(offset);
              expect(offset, lessThan(count));
              return {
                'sessions': [
                  for (var i = offset; i < count && i < offset + 200; i++)
                    row(i),
                ],
                'offset': offset,
                'limit': 200,
                'total': count,
              };
            },
            legacyGatewayLoader: () async => fail('Unexpected fallback'),
          ),
        );
        addTearDown(repository.close);

        final snapshot = await repository.load();
        expect(snapshot.sessions.map((s) => s.id), [
          for (var i = 0; i < count; i++) 'session-$i',
        ]);
        expect(
          snapshot.sessions.map((s) => (s.profile, s.id)).toSet(),
          hasLength(count),
        );
        expect(snapshot.sessionsCapability, MissionCapabilityState.available);
        expect(snapshot.failures, isEmpty);
        expect(offsets, [for (var i = 0; i < count; i += 200) i]);
      },
    );
  }

  test(
    'boundary duplicates keep first row and distinct owner and physical IDs',
    () async {
      final offsets = <int>[];
      final sessions = await loadMissionControlSessions(
        dashboardGet: (endpoint) async {
          final offset = int.parse(
            Uri.parse(endpoint).queryParameters['offset']!,
          );
          offsets.add(offset);
          expect(offsets.length, lessThanOrEqualTo(2));
          return {
            'sessions': offset == 0
                ? [
                    for (var i = 0; i < 200; i++)
                      {
                        ...row(i),
                        'title': 'first-$i',
                        '_lineage_root_id': 'shared-root',
                      },
                  ]
                : [
                    {
                      ...row(199, profile: ' default '),
                      'title': 'later-duplicate',
                    },
                    row(199, profile: 'other'),
                    {...row(200), '_lineage_root_id': 'shared-root'},
                    row(200),
                  ],
          };
        },
        legacyGatewayLoader: () async => fail('Unexpected fallback'),
      );
      expect(offsets, [0, 200]);
      expect(sessions[199].lineageRootId, 'shared-root');
      expect(sessions.last.lineageRootId, sessions[199].lineageRootId);
      expect(sessions.map((s) => (s.profile, s.id)), [
        for (var i = 0; i < 200; i++) ('default', 'session-$i'),
        ('other', 'session-199'),
        ('default', 'session-200'),
      ]);
      expect(sessions[199].title, 'first-199');
    },
  );

  for (final total in <int?>[null, 201]) {
    test(
      'hidden auxiliary first page does not stop paging (total=$total)',
      () async {
        final offsets = <int>[];
        final sessions = await loadMissionControlSessions(
          dashboardGet: (endpoint) async {
            final offset = int.parse(
              Uri.parse(endpoint).queryParameters['offset']!,
            );
            offsets.add(offset);
            expect(offsets.length, lessThanOrEqualTo(2));
            return {
              'data': [
                if (offset == 0)
                  for (var i = 0; i < 200; i++)
                    {'id': 'mob-aux-$i', 'profile': 'default'}
                else
                  row(200),
              ],
              'total': ?total,
            };
          },
          legacyGatewayLoader: () async => fail('Unexpected fallback'),
        );
        expect(offsets, [0, 200]);
        expect(sessions.map((s) => s.id), ['session-200']);
      },
    );
  }

  for (final error in <Object>[
    const DashboardHttpException(401),
    const DashboardHttpException(404),
    const DashboardHttpException(405),
    const DashboardHttpException(500),
    TimeoutException('later page timed out'),
  ]) {
    test(
      'repository records later $error without exposing partial sessions',
      () async {
        final offsets = <int>[];
        final board = const KanbanBoard(columns: []);
        final repository = MissionControlRepository(
          profilesLoader: () async => [],
          boardLoader: () async => board,
          sessionsLoader: () => loadMissionControlSessions(
            dashboardGet: (endpoint) async {
              final offset = int.parse(
                Uri.parse(endpoint).queryParameters['offset']!,
              );
              offsets.add(offset);
              if (offset == 400) throw error;
              expect(offset, lessThan(400));
              return {
                'sessions': [
                  for (var i = offset; i < offset + 200; i++) row(i),
                ],
              };
            },
            legacyGatewayLoader: () async => fail('Unexpected fallback'),
          ),
        );
        addTearDown(repository.close);
        final snapshot = await repository.load();
        expect(offsets, [0, 200, 400]);
        expect(snapshot.sessions, isEmpty);
        expect(snapshot.failures.keys, ['sessions']);
        expect(snapshot.failures['sessions'], same(error));
        final unsupported =
            error is DashboardHttpException &&
            (error.statusCode == 404 || error.statusCode == 405);
        expect(
          snapshot.sessionsCapability,
          unsupported
              ? MissionCapabilityState.unsupported
              : MissionCapabilityState.unavailable,
        );
        expect(snapshot.board, same(board));
        expect(snapshot.kanbanCapability, MissionCapabilityState.available);
        expect(snapshot.profilesCapability, MissionCapabilityState.available);
      },
    );
  }

  final malformedLaterPages = <String, Map<String, dynamic>>{
    'missing rows': {},
    'non-list rows': {'sessions': {}},
    'missing owner': {
      'sessions': [
        {'id': 'ownerless'},
      ],
    },
    'invalid row': {
      'sessions': [42],
    },
    'zero stride': {
      'sessions': [row(200)],
      'limit': 0,
    },
    'string stride': {
      'sessions': [row(200)],
      'limit': '200',
    },
    'wrong offset': {
      'sessions': [row(200)],
      'offset': 0,
    },
    'negative total': {
      'sessions': [row(200)],
      'total': -1,
    },
    'string total': {
      'sessions': [row(200)],
      'total': '201',
    },
    'profile error map': {
      'sessions': [row(200)],
      'errors': {'other': 'offline'},
    },
    'profile error string': {
      'sessions': [row(200)],
      'errors': 'offline',
    },
  };
  for (final entry in malformedLaterPages.entries) {
    test('later ${entry.key} fails closed', () async {
      final offsets = <int>[];
      await expectLater(
        loadMissionControlSessions(
          dashboardGet: (endpoint) async {
            final offset = int.parse(
              Uri.parse(endpoint).queryParameters['offset']!,
            );
            offsets.add(offset);
            expect(offsets.length, lessThanOrEqualTo(2));
            return offset == 0
                ? {
                    'sessions': [for (var i = 0; i < 200; i++) row(i)],
                  }
                : entry.value;
          },
          legacyGatewayLoader: () async => fail('Unexpected fallback'),
        ),
        throwsFormatException,
      );
      expect(offsets, [0, 200]);
    });
  }

  for (final count in [0, 200, 201, 401]) {
    test('loads $count sessions without pagination metadata', () async {
      final offsets = <int>[];
      final sessions = await loadMissionControlSessions(
        dashboardGet: (endpoint) async {
          final query = Uri.parse(endpoint).queryParameters;
          expect(query['profile'], 'all');
          expect(query['limit'], '200');
          expect(query['include_children'], 'true');
          final offset = int.parse(query['offset']!);
          offsets.add(offset);
          return {
            'sessions': [
              for (var i = offset; i < count && i < offset + 200; i++) row(i),
            ],
          };
        },
        legacyGatewayLoader: () async => fail('Unexpected fallback'),
      );
      expect(sessions.map((s) => s.id), [
        for (var i = 0; i < count; i++) 'session-$i',
      ]);
      expect(offsets, [for (var i = 0; i <= count ~/ 200; i++) i * 200]);
      expect(() => sessions.clear(), throwsUnsupportedError);
    });
  }

  test(
    'uses server stride despite appended pins and profile duplicates',
    () async {
      final offsets = <int>[];
      final sessions = await loadMissionControlSessions(
        dashboardGet: (endpoint) async {
          final offset = int.parse(
            Uri.parse(endpoint).queryParameters['offset']!,
          );
          offsets.add(offset);
          return {
            'sessions': [
              for (var i = offset; i < 5 && i < offset + 2; i++) row(i),
              row(4),
              row(4, profile: 'other'),
              {'id': 'mob-aux-hidden', 'profile': 'default'},
            ],
            'offset': offset,
            'limit': 2,
            'total': 5,
          };
        },
        legacyGatewayLoader: () async => fail('Unexpected fallback'),
      );
      expect(offsets, [0, 2, 4]);
      expect(sessions.map((s) => (s.profile, s.id)).toSet(), {
        for (var i = 0; i < 5; i++) ('default', 'session-$i'),
        ('other', 'session-4'),
      });
      expect(sessions, hasLength(6));
    },
  );

  for (final status in [401, 404, 405, 500]) {
    test(
      'later HTTP $status fails without fallback or partial results',
      () async {
        final error = DashboardHttpException(status);
        await expectLater(
          loadMissionControlSessions(
            dashboardGet: (endpoint) async {
              if (Uri.parse(endpoint).queryParameters['offset'] != '0') {
                throw error;
              }
              return {
                'sessions': [for (var i = 0; i < 200; i++) row(i)],
              };
            },
            legacyGatewayLoader: () async => fail('Unexpected fallback'),
          ),
          throwsA(same(error)),
        );
      },
    );
  }

  test('later partial aggregate fails closed', () async {
    await expectLater(
      loadMissionControlSessions(
        dashboardGet: (endpoint) async => {
          'sessions': [for (var i = 0; i < 200; i++) row(i)],
          if (Uri.parse(endpoint).queryParameters['offset'] != '0')
            'errors': ['profile unavailable'],
        },
        legacyGatewayLoader: () async => fail('Unexpected fallback'),
      ),
      throwsFormatException,
    );
  });

  for (final total in <int?>[null, 400]) {
    test(
      'repeated full page with total=$total fails rather than truncating',
      () async {
        var calls = 0;
        await expectLater(
          loadMissionControlSessions(
            dashboardGet: (_) async {
              calls++;
              expect(calls, lessThanOrEqualTo(2));
              return {
                'sessions': [for (var i = 0; i < 200; i++) row(i)],
                'total': ?total,
              };
            },
            legacyGatewayLoader: () async => fail('Unexpected fallback'),
          ),
          throwsFormatException,
        );
        expect(calls, 2);
      },
    );
  }

  test('empty later page before advertised total fails closed', () async {
    await expectLater(
      loadMissionControlSessions(
        dashboardGet: (endpoint) async => {
          'sessions': [
            if (Uri.parse(endpoint).queryParameters['offset'] == '0')
              for (var i = 0; i < 200; i++) row(i),
          ],
          'total': 201,
        },
        legacyGatewayLoader: () async => fail('Unexpected fallback'),
      ),
      throwsFormatException,
    );
  });
}
