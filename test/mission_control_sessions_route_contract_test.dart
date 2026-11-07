import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              'test/fixtures/mission_sessions_capped_route.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final scenarios = fixture['scenarios'] as Map<String, dynamic>;

  // Recorded from the real pre-fix Dashboard route and temporary SessionDBs.
  // These assert honest unavailability, NOT complete retrieval on that backend.
  for (final name in scenarios.keys) {
    test(
      'real capped route $name never reports incomplete rows healthy',
      () async {
        final scenario = scenarios[name] as Map<String, dynamic>;
        final pages = scenario['pages'] as List;
        final counts = scenario['counts'] as Map<String, dynamic>;
        final expected = {
          for (final owner in counts.keys)
            for (var i = 0; i < (counts[owner] as int); i++)
              (owner, 'session-$i'),
        };
        final recorded = {
          for (final page in pages)
            for (final row in page['sessions'])
              (row['profile'] as String, row['id'] as String),
        };
        final complete =
            name == 'mixed_complete_pinned' ||
            name == 'mixed_pin_recovers_boundary';
        expect(recorded.length == expected.length, complete);
        final offsets = <int>[];
        final repository = MissionControlRepository(
          profilesLoader: () async => [],
          boardLoader: () async => const KanbanBoard(columns: []),
          sessionsLoader: () => loadMissionControlSessions(
            dashboardGet: (endpoint) async {
              final query = Uri.parse(endpoint).queryParameters;
              expect(query['profile'], 'all');
              expect(query['limit'], '200');
              final offset = int.parse(query['offset']!);
              offsets.add(offset);
              return Map<String, dynamic>.from(
                pages.singleWhere((p) => p['offset'] == offset) as Map,
              );
            },
            legacyGatewayLoader: () async => fail('Unexpected legacy fallback'),
          ),
        );
        addTearDown(repository.close);
        final snapshot = await repository.load();
        expect(offsets, [for (final page in pages) page['offset']]);
        if (complete) {
          expect(
            snapshot.sessions.map((s) => (s.profile, s.id)).toSet(),
            expected,
          );
          expect(snapshot.sessionsCapability, MissionCapabilityState.available);
          expect(snapshot.failures, isEmpty);
        } else {
          expect(snapshot.sessions, isEmpty);
          expect(
            snapshot.sessionsCapability,
            MissionCapabilityState.unavailable,
          );
          expect(snapshot.failures.keys, ['sessions']);
          expect(snapshot.failures['sessions'], isA<FormatException>());
        }
        expect(snapshot.profilesCapability, MissionCapabilityState.available);
        expect(snapshot.kanbanCapability, MissionCapabilityState.available);
      },
    );
  }

  test('extra rows from another owner cannot mask a profile deficit', () async {
    await expectLater(
      loadMissionControlSessions(
        dashboardGet: (_) async => {
          'sessions': [
            {'id': 'a', 'profile': 'default'},
            {'id': 'b', 'profile': 'other'},
            {'id': 'c', 'profile': 'other'},
          ],
          'total': 3,
          'profile_totals': {'default': 2, 'other': 1},
        },
        legacyGatewayLoader: () async => fail('Unexpected fallback'),
      ),
      throwsFormatException,
    );
  });

  test('hidden auxiliary rows count toward advertised completeness', () async {
    final sessions = await loadMissionControlSessions(
      dashboardGet: (_) async => {
        'sessions': [
          {'id': 'mob-aux-hidden', 'profile': 'default'},
          {'id': 'visible', 'profile': 'default'},
        ],
        'total': 2,
        'profile_totals': {'default': 2},
      },
      legacyGatewayLoader: () async => fail('Unexpected fallback'),
    );
    expect(sessions.map((s) => s.id), ['visible']);
  });

  for (final useProfileTotals in [false, true]) {
    test(
      'later counts cannot erase an earlier deficit ($useProfileTotals)',
      () async {
        await expectLater(
          loadMissionControlSessions(
            dashboardGet: (endpoint) async {
              final offset = int.parse(
                Uri.parse(endpoint).queryParameters['offset']!,
              );
              return {
                'sessions': [
                  {'id': 'session-$offset', 'profile': 'default'},
                ],
                'limit': 1,
                'offset': offset,
                'total': useProfileTotals ? 2 : (offset == 0 ? 3 : 2),
                if (useProfileTotals)
                  'profile_totals': {'default': offset == 0 ? 3 : 2},
              };
            },
            legacyGatewayLoader: () async => fail('Unexpected fallback'),
          ),
          throwsFormatException,
        );
      },
    );
  }

  for (final malformed in <Object>[
    [],
    {'default': -1},
    {'default': '1'},
    {'': 1},
  ]) {
    test('malformed profile totals $malformed fail closed', () async {
      await expectLater(
        loadMissionControlSessions(
          dashboardGet: (_) async => {
            'sessions': [
              {'id': 'a', 'profile': 'default'},
            ],
            'total': 1,
            'profile_totals': malformed,
          },
          legacyGatewayLoader: () async => fail('Unexpected fallback'),
        ),
        throwsFormatException,
      );
    });
  }
}
