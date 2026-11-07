import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/inter_font.dart';
import 'support/spec070_fixtures.dart';

HostedGroupRoom _room(String id, {int? revision}) => HostedGroupRoom.fromJson({
  ...Map<String, dynamic>.from(spec070Result('groups_state')['room'] as Map),
  'room_id': id,
  'name': id == 'healthy' ? 'Healthy room' : 'Failed room',
  'revision': ?revision,
});

HostedGroupLogPage _log(String id, int since) => HostedGroupLogPage.fromJson(
  {
    'events': [
      if (since == 0)
        {
          ...Map<String, dynamic>.from(
            (spec070Result('groups_log_page1')['events'] as List).first as Map,
          ),
          'room_id': id,
          'seq': 1,
        },
    ],
    'cursor': 1,
    'latest_seq': 1,
    'has_more': false,
    'authority': spec070Result('groups_log_page1')['authority'],
  },
  expectedRoomId: id,
  sinceSeq: since,
);

class _Gateway
    implements
        MissionHostedGroupsGateway,
        MissionHostedGroupsIncrementalGateway {
  _Gateway(this.failure, {this.failedFirst = true});
  String? failure;
  final bool failedFirst;
  bool failAll = false;
  final calls = <(String, int)>[];
  final error = StateError('private failure detail');

  bool _fails(String id) => failure != null && (id == 'failed' || failAll);

  @override
  Future<GroupsCapabilities> capabilities() async => spec070Capabilities();

  @override
  Future<List<HostedGroupRoom>> list({required int generation}) async {
    if (failure == 'list') throw error;
    return [
      for (final id
          in failedFirst ? ['failed', 'healthy'] : ['healthy', 'failed'])
        _room(id),
    ];
  }

  @override
  Future<HostedGroupRoom> state(String id, {required int generation}) async {
    expect(generation, 1);
    if (_fails(id)) {
      if (failure == 'state') throw error;
      if (failure == 'identity') return _room('wrong-room');
      if (failure == 'revision') return _room(id, revision: 0);
    }
    return _room(id);
  }

  @override
  Future<HostedGroupLogPage> log(String id, {required int generation}) =>
      logSince(id, sinceSeq: 0, limit: 50, generation: generation);

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})>
  stateWithDriver(String id, {required int generation}) async => (
    room: await state(id, generation: generation),
    driverStatus: spec070DriverStatus(),
  );

  @override
  Future<HostedGroupLogPage> logSince(
    String id, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    expect(generation, 1);
    calls.add((id, sinceSeq));
    if (_fails(id) && failure == 'log') throw error;
    return _log(id, sinceSeq);
  }

  MissionHostedGroupsGateway legacy() => MissionHostedGroupsGateway.callbacks(
    capabilities: capabilities,
    list: list,
    state: state,
    log: log,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MissionControlRepository _repository(MissionHostedGroupsGateway gateway) =>
    MissionControlRepository(
      profilesLoader: () async => [],
      sessionsLoader: () async => [],
      boardLoader: () async => const KanbanBoard(columns: []),
      hostedGroupsGateway: gateway,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadInterFont);

  for (final incremental in [false, true]) {
    for (final failedFirst in [false, true]) {
      for (final failure in ['state', 'log', 'identity', 'revision']) {
        test(
          'partial room $failure incremental=$incremental failedFirst=$failedFirst recovers',
          () async {
            final gateway = _Gateway(failure, failedFirst: failedFirst);
            final repository = _repository(
              incremental ? gateway : gateway.legacy(),
            );
            addTearDown(repository.close);
            final partial = await repository.load();
            expect(
              partial.hostedGroupsCapability,
              MissionCapabilityState.available,
            );
            expect(partial.hostedGroups.rooms.map((r) => r.roomId), [
              'healthy',
            ]);
            expect(
              partial.hostedGroups.logs.single.events.single.roomId,
              'healthy',
            );
            expect(partial.hostedGroups.roomFailures.keys, ['failed']);
            expect(partial.failures.keys, ['hostedGroups']);
            expect(
              partial.failures['hostedGroups'],
              same(partial.hostedGroups.roomFailures),
            );
            expect(
              partial.hostedGroups.roomFailures['failed'],
              failure == 'state' || failure == 'log'
                  ? same(gateway.error)
                  : isA<FormatException>(),
            );
            expect(
              () => partial.hostedGroups.roomFailures.clear(),
              throwsUnsupportedError,
            );
            expect(
              partial.hostedGroups.driverStatuses.keys,
              incremental ? ['healthy'] : isEmpty,
            );

            gateway.failure = null;
            gateway.calls.clear();
            final recovered = await repository.load();
            expect(
              recovered.hostedGroups.rooms.map((r) => r.roomId),
              unorderedEquals(['healthy', 'failed']),
            );
            expect(recovered.hostedGroups.logs, hasLength(2));
            expect(recovered.hostedGroups.roomFailures, isEmpty);
            expect(recovered.failures, isEmpty);
            // Failed cursors restart; healthy cursors keep their verified history.
            expect(gateway.calls, contains(('failed', 0)));
            expect(gateway.calls, contains(('healthy', incremental ? 1 : 0)));
          },
        );
      }
    }
  }

  test(
    'all room failures remain observable, not a healthy empty result',
    () async {
      final gateway = _Gateway('log')..failAll = true;
      final repository = _repository(gateway);
      addTearDown(repository.close);
      final snapshot = await repository.load();
      expect(snapshot.hostedGroups.rooms, isEmpty);
      expect(
        snapshot.hostedGroups.roomFailures.keys,
        unorderedEquals(['failed', 'healthy']),
      );
      expect(
        snapshot.failures['hostedGroups'],
        same(snapshot.hostedGroups.roomFailures),
      );
    },
  );

  test('list failure remains a surface-level unavailable result', () async {
    final gateway = _Gateway('list');
    final repository = _repository(gateway);
    addTearDown(repository.close);
    final snapshot = await repository.load();
    expect(snapshot.hostedGroupsCapability, MissionCapabilityState.unavailable);
    expect(snapshot.failures['hostedGroups'], same(gateway.error));
    expect(snapshot.hostedGroups.rooms, isEmpty);
  });

  for (final locale in ['en', 'es']) {
    testWidgets(
      'real repository partial result shows healthy row and safe notice in $locale',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        addTearDown(manager.dispose);
        final repository = _repository(_Gateway('log'));
        addTearDown(repository.close);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            theme: AppTheme.fromId('dark'),
            home: MissionControlScreen(
              connection: SavedConnection(
                id: 'fixture',
                label: 'Fixture',
                host: '127.0.0.1',
                port: 8642,
                apiKey: '',
              ),
              connManager: manager,
              dataSource: repository,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final strings = Strings.of(
          tester.element(find.byType(MissionControlScreen)),
        );
        expect(find.text('Healthy room'), findsOneWidget);
        expect(find.text('Failed room'), findsNothing);
        expect(find.text(strings.missionStaleData), findsOneWidget);
        expect(find.textContaining('private failure detail'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
