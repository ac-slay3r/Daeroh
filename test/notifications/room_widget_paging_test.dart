import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_mode_widget_snapshot.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart'
    show approvalAction, driver, EventSeq, memberJson;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Gateway gateway;
  late SharedPreferences prefs;
  late BotModeBackgroundMonitor monitor;
  late BotModeWidgetSnapshot latest;
  late DateTime now;
  late List<SavedConnection> targets;

  Future<void> tick() async {
    gateway.polled.clear();
    await monitor.tick(
      prefs: prefs,
      targets: targets,
      notificationsEnabled: true,
    );
    now = now.add(const Duration(minutes: 1));
    expect(gateway.polled.length, lessThanOrEqualTo(12));
    expect(gateway.polled.toSet().length, gateway.polled.length);
  }

  Future<void> observeApproval() async {
    await tick();
    expect(gateway.polled, isNot(contains('room-13')));
    expect(
      latest.approvals,
      isEmpty,
    ); // No invented evidence before first read.
    await tick();
    expect(gateway.polled, contains('room-13'));
    expect(latest.approvals.single.requestId, 'apr-13');
    expect(latest.bots.single.state, WidgetBotState.needsYou);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({'last_connection_id': 'c1'});
    prefs = await SharedPreferences.getInstance();
    gateway = _Gateway();
    final dir = await Directory.systemTemp.createTemp('room-widget-paging');
    addTearDown(() => dir.delete(recursive: true));
    now = DateTime(2026, 9, 26, 12);
    targets = [
      for (final id in ['c1', 'c2']) _connection(id),
    ];
    monitor = BotModeBackgroundMonitor(
      sink: _Sink(),
      faces: BotFaceBitmapCache(directory: () async => dir),
      now: () => now,
      publish: (snapshot) async => latest = snapshot,
      gatewayFor: (_) => gateway,
    );
    addTearDown(monitor.close);
  });

  for (final reorder in [false, true]) {
    test(
      'retains approval identity and bot attention across skips reorder=$reorder',
      () async {
        gateway.reorder = reorder;
        await observeApproval();
        final action = latest.approvals.single.actionPayload;
        final open = latest.approvals.single.openPayload;
        var skips = 0;
        for (var pass = 0; pass < 26; pass++) {
          await tick();
          if (!gateway.polled.contains('room-13')) skips++;
          expect(latest.approvals.single.requestId, 'apr-13');
          expect(latest.approvals.single.actionPayload, action);
          expect(latest.approvals.single.openPayload, open);
          expect(latest.approvals.single.canApprove, isTrue);
          expect(latest.bots.single.state, WidgetBotState.needsYou);
        }
        expect(skips, greaterThanOrEqualTo(2));
      },
    );
  }

  test(
    'successful read of true completion clears approval and ends attention',
    () async {
      await observeApproval();
      gateway.pending = false;
      await tick();
      expect(gateway.polled, contains('room-13'));
      expect(latest.approvals, isEmpty);
      expect(latest.bots.single.state, WidgetBotState.done);
      for (var pass = 0; pass < 14; pass++) {
        await tick();
        expect(latest.approvals, isEmpty);
        expect(latest.bots.single.state, isNot(WidgetBotState.needsYou));
      }
    },
  );

  for (final disbanded in [false, true]) {
    test(
      'prunes cached evidence on ${disbanded ? 'disbanding' : 'removal'} and does not resurrect it',
      () async {
        await observeApproval();
        if (disbanded) {
          gateway.rooms[12] = _room(13, disbanded: true);
        } else {
          gateway.rooms.removeLast();
        }
        await tick();
        expect(gateway.polled, isNot(contains('room-13')));
        expect(latest.approvals, isEmpty);
        expect(latest.rooms.map((r) => r.roomId), isNot(contains('room-13')));
        expect(latest.bots.single.state, isNot(WidgetBotState.needsYou));
        gateway.rooms.removeWhere((r) => r.roomId == 'room-13');
        gateway.rooms.add(_room(13));
        gateway.failures.add('room-13');
        for (var pass = 0; pass < 2; pass++) {
          await tick();
          expect(latest.approvals, isEmpty);
        }
      },
    );
  }

  for (final allFail in [false, true]) {
    test(
      'retains unknown evidence during ${allFail ? 'total' : 'partial'} read failure then adopts recovery',
      () async {
        await observeApproval();
        gateway.failures.addAll(
          allFail ? gateway.rooms.map((r) => r.roomId) : ['room-13'],
        );
        gateway.pending = false; // Not yet observed; failure is not completion.
        await tick();
        expect(gateway.polled, contains('room-13'));
        expect(latest.approvals.single.requestId, 'apr-13');
        expect(latest.bots.single.state, WidgetBotState.needsYou);
        gateway.failures.clear();
        now = now.add(const Duration(hours: 1));
        await tick();
        expect(gateway.polled, contains('room-13'));
        expect(latest.approvals, isEmpty);
        expect(latest.bots.single.state, WidgetBotState.done);
      },
    );
  }

  test(
    'failed log read retains attention until a complete successful read',
    () async {
      await observeApproval();
      gateway.rooms[12] = _room(13, latestSeq: 8);
      gateway.pending = false;
      gateway.failLog = true;
      await tick();
      expect(gateway.polled, contains('room-13'));
      expect(latest.approvals.single.requestId, 'apr-13');
      expect(latest.bots.single.state, WidgetBotState.needsYou);
      gateway.failLog = false;
      await tick();
      expect(latest.approvals, isEmpty);
      expect(latest.bots.single.state, WidgetBotState.done);
    },
  );

  test(
    'connection switch clears evidence even for identical room and profile IDs',
    () async {
      await observeApproval();
      await prefs.setString('last_connection_id', 'c2');
      gateway.pending = false;
      await tick();
      expect(latest.connectionId, 'c2');
      expect(gateway.polled, isNot(contains('room-13')));
      expect(latest.approvals, isEmpty);
      expect(latest.bots.single.state, WidgetBotState.idle);
      await prefs.setString('last_connection_id', 'c1');
      await tick();
      expect(latest.connectionId, 'c1');
      expect(gateway.polled, isNot(contains('room-13')));
      expect(latest.approvals, isEmpty);
      expect(latest.bots.single.state, WidgetBotState.idle);
    },
  );
}

SavedConnection _connection(String id) => SavedConnection.fromMap({
  'id': id,
  'label': 'Fixture',
  'host': '127.0.0.1',
  'port': 1,
  'apiKey': '',
  'useHttps': false,
});

final class _Gateway implements BotModeGateway {
  final rooms = [for (var i = 1; i <= 13; i++) _room(i)];
  final polled = <String>[];
  final failures = <String>{};
  bool pending = true;
  bool reorder = false;
  bool failLog = false;
  int listingPass = 0;

  @override
  Future<GroupsCapabilities> groupCapabilities() async =>
      GroupsCapabilities.tryParse(
        {
          'protocol_version': 1,
          'driver': true,
          'max_log_limit': 500,
          'methods': [for (final method in GroupMethod.values) method.wire],
        },
        connectionId: 'c1',
        generation: 1,
      )!;

  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) async {
    if (!reorder) return [...rooms];
    final offset = listingPass++ % rooms.length;
    return [...rooms.skip(offset), ...rooms.take(offset)];
  }

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) async {
    polled.add(roomId);
    if (failures.contains(roomId)) throw StateError('room unavailable');
    return (
      room: rooms.singleWhere((r) => r.roomId == roomId),
      driverStatus: driver(
        pending: [
          if (roomId == 'room-13' && pending) approvalAction(request: 'apr-13'),
        ],
      ),
    );
  }

  @override
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    if (failLog) throw StateError('log unavailable');
    final event = (EventSeq()..seq = sinceSeq).user('recovered')
      ..['room_id'] = roomId;
    return HostedGroupLogPage.fromJson(
      {
        'events': [event],
        'cursor': 8,
        'latest_seq': 8,
        'has_more': false,
        'authority': {'gateway_id': 'gw-home-1', 'epoch': 2},
      },
      expectedRoomId: roomId,
      sinceSeq: sinceSeq,
    );
  }

  @override
  Future<List<AgentProfile>> listProfiles() async => const [
    AgentProfile(name: 'lead'),
  ];
  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HostedGroupRoom _room(
  int number, {
  bool disbanded = false,
  int latestSeq = 7,
}) => HostedGroupRoom.fromJson({
  'room_id': 'room-$number',
  'name': 'Room $number',
  'members': [if (number == 13) memberJson('m-lead', 'lead')],
  'authority_gateway_id': 'gw-home-1',
  'authority_epoch': 2,
  'revision': 1,
  'created_at': 1790000000.0,
  'updated_at': 1790000500.0,
  'latest_seq': latestSeq,
  if (disbanded) 'disbanded_at': 1790000600.0,
});

final class _Sink implements RichNotificationSink {
  @override
  Future<void> cancel({required int id, String? tag}) async {}
  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
  @override
  Future<bool> postConversation(Map<String, Object?> args) async => true;
  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {}
}
