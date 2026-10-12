import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart' show approvalAction, driver, EventSeq;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late _ThirteenRoomGateway gateway;
  late _RecordingPresenter presenter;
  late RoomWatcher watcher;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    gateway = _ThirteenRoomGateway();
    presenter = _RecordingPresenter();
    watcher = RoomWatcher(
      connId: 'c1',
      prefs: prefs,
      presenter: presenter,
      claim: (_, _, _) async => true,
      release: (_, _, _) async {},
    );
  });

  test('a pending approval in room 13 is eventually presented', () async {
    gateway.pendingByRoom['room-13'] = [approvalAction(request: 'apr-13')];

    for (var pass = 0; pass < 4; pass++) {
      expect(await watcher.tick(gateway), isTrue);
      if (presenter.approvals.any((entry) => entry.roomId == 'room-13')) {
        break;
      }
    }

    expect(
      presenter.approvals.where((entry) => entry.roomId == 'room-13'),
      hasLength(1),
    );
    expect(presenter.approvals.single.requestId, 'apr-13');
  });

  test(
    'mixed failures retain state and cannot starve tail approvals',
    () async {
      final failedKey = RoomWatcher.roomKey('c1', gateway.rooms.first);
      final saved = const RoomWatchState(
        cursor: 6,
        pendingRequestIds: {'old'},
      ).toJson();
      await prefs.setString(
        RoomWatcher.storageKey,
        jsonEncode({failedKey: saved}),
      );
      gateway.failures.add('room-1');
      gateway.pendingByRoom['room-13'] = [approvalAction(request: 'apr-13')];
      expect(await watcher.tick(gateway), isTrue);
      expect(gateway.polled.length, 12);
      expect(
        watcher.views.map((v) => v.room.roomId),
        isNot(contains('room-1')),
      );
      expect(watcher.listedRoomIds, contains('room-1'));
      expect(_savedStates(prefs)[failedKey], saved);
      expect(await watcher.tick(gateway), isTrue);
      expect(presenter.approvals.single.roomId, 'room-13');
      for (var i = 0; i < 3; i++) {
        expect(await watcher.tick(gateway), isTrue);
      }
      expect(presenter.approvals, hasLength(1));
      expect(_savedStates(prefs)[failedKey], saved);
      final healthyKey = RoomWatcher.roomKey('c1', gateway.rooms.last);
      expect(
        RoomWatchState.fromJson(_savedStates(prefs)[healthyKey]).cursor,
        7,
      );
      // A log read failure is isolated too and cannot advance its saved cursor.
      gateway.failures.clear();
      expect(await watcher.tick(gateway), isTrue);
      expect(_savedStates(prefs)[failedKey], saved);
      gateway.logRecovers = true;
      for (var i = 0; i < 2; i++) {
        expect(await watcher.tick(gateway), isTrue);
      }
      expect(RoomWatchState.fromJson(_savedStates(prefs)[failedKey]).cursor, 7);
      expect(presenter.approvals, hasLength(1));
    },
  );

  test('all failures back off but rotate and recover', () async {
    var now = DateTime(2026);
    watcher = RoomWatcher(
      connId: 'c1',
      prefs: prefs,
      presenter: presenter,
      claim: (_, _, _) async => true,
      release: (_, _, _) async {},
      now: () => now,
    );
    gateway.failures.addAll(gateway.rooms.map((room) => room.roomId));
    expect(await watcher.tick(gateway), isFalse);
    expect(watcher.views, isEmpty);
    expect(watcher.retryAfter, const Duration(minutes: 1));
    expect(gateway.polled.length, 12);
    expect(await watcher.tick(gateway), isFalse);
    expect(gateway.polled.length, 12);
    now = now.add(const Duration(minutes: 1));
    expect(await watcher.tick(gateway), isFalse);
    expect(gateway.polled[12], 'room-13');
    expect(watcher.retryAfter, const Duration(minutes: 2));
    now = now.add(const Duration(minutes: 2));
    gateway.failures.clear();
    expect(await watcher.tick(gateway), isTrue);
    expect(watcher.retryAfter, isNull);
    expect(watcher.views, hasLength(12));
  });

  test('repeated passes reach every room and keep unvisited state', () async {
    final saved = <String, Object?>{
      for (final room in gateway.rooms)
        RoomWatcher.roomKey('c1', room): const RoomWatchState(
          cursor: 7,
          pendingRequestIds: {'already-seen'},
        ).toJson(),
    };
    await prefs.setString(RoomWatcher.storageKey, jsonEncode(saved));
    // A still-pending approval must not be announced again when room 13 is
    // eventually polled; its saved cursor and pending IDs must survive skips.
    gateway.pendingByRoom['room-13'] = [
      approvalAction(request: 'already-seen'),
    ];

    expect(await watcher.tick(gateway), isTrue);
    final firstVisited = gateway.polled.toSet();
    expect(firstVisited.length, lessThan(gateway.rooms.length));
    final firstSaved = _savedStates(prefs);
    for (final room in gateway.rooms.where(
      (room) => !firstVisited.contains(room.roomId),
    )) {
      final key = RoomWatcher.roomKey('c1', room);
      expect(firstSaved[key], saved[key], reason: '$key was not polled');
    }

    for (var pass = 0; pass < 4; pass++) {
      expect(await watcher.tick(gateway), isTrue);
    }
    expect(gateway.polled.toSet(), {
      for (final room in gateway.rooms) room.roomId,
    });
    expect(gateway.polled, contains('room-13'));
    expect(
      presenter.approvals.where((entry) => entry.roomId == 'room-13'),
      isEmpty,
      reason: 'the persisted approval identity must survive skipped passes',
    );
    final lastSaved = _savedStates(prefs);
    expect(lastSaved.keys, containsAll(saved.keys));
    final lastKey = RoomWatcher.roomKey('c1', gateway.rooms.last);
    expect(RoomWatchState.fromJson(lastSaved[lastKey]).pendingRequestIds, {
      'already-seen',
    });
  });
  for (final reorder in [false, true]) {
    test('every two passes reach all 13 rooms (reorder=$reorder)', () async {
      gateway.reorder = reorder;
      gateway.pendingByRoom['room-13'] = [approvalAction(request: 'apr-13')];
      final expected = gateway.rooms.map((room) => room.roomId).toSet();
      // Check successive windows, not just the cumulative set: a room must
      // continue to be reachable after its first visit. No timing/sleeps.
      for (var window = 0; window < 13; window++) {
        final seen = <String>{};
        for (var pass = 0; pass < 2; pass++) {
          gateway.polled.clear();
          expect(await watcher.tick(gateway), isTrue);
          expect(gateway.polled, hasLength(12));
          expect(gateway.polled.toSet(), hasLength(12));
          seen.addAll(gateway.polled);
        }
        expect(seen, expected, reason: 'window $window');
        expect(presenter.approvals, hasLength(1));
        expect(presenter.approvals.single, (
          roomId: 'room-13',
          requestId: 'apr-13',
        ));
      }
    });
  }

  test('every skipped room retains its complete serialized state', () async {
    gateway.reorder = true;
    final saved = {
      for (final room in gateway.rooms)
        RoomWatcher.roomKey('c1', room): const RoomWatchState(
          cursor: 7,
          working: true,
          blocked: true,
          repliers: ['member-a'],
          lastMemberId: 'member-a',
          pendingRequestIds: {'already-seen'},
          workingSinceMs: 100,
          round: 3,
          openMembers: {'member-b'},
          discussion: 'discussion-a',
          roundFromSeq: 2,
          roundOpenSinceMs: 100,
          finishedDiscussion: 'previous-discussion',
          addressed: ['builder'],
          roundUserAtMs: 100,
          repliedAfterMs: {'member-a': 20},
        ).toJson(),
    };
    await prefs.setString(RoomWatcher.storageKey, jsonEncode(saved));
    final skipped = <String>{};
    for (var pass = 0; pass < 13; pass++) {
      final before = _savedStates(prefs);
      gateway.polled.clear();
      expect(await watcher.tick(gateway), isTrue);
      final after = _savedStates(prefs);
      expect(after.keys.toSet(), saved.keys.toSet());
      final room = gateway.rooms.singleWhere(
        (r) => !gateway.polled.contains(r.roomId),
      );
      final key = RoomWatcher.roomKey('c1', room);
      expect(after[key], before[key], reason: 'pass $pass skipped $key');
      skipped.add(room.roomId);
    }
    expect(skipped, hasLength(13));
  });

  for (final budget in [-1, 0, 1, 12, 13, 20]) {
    test('budget $budget bounds reads without losing saved state', () async {
      watcher = RoomWatcher(
        connId: 'c1',
        prefs: prefs,
        presenter: presenter,
        claim: (_, _, _) async => true,
        release: (_, _, _) async {},
        maxRooms: budget,
      );
      final saved = {
        for (final room in gateway.rooms)
          RoomWatcher.roomKey('c1', room): const RoomWatchState(
            cursor: 7,
          ).toJson(),
        RoomWatcher.roomKey('c1', _room(99)): const RoomWatchState(
          cursor: 99,
        ).toJson(),
      };
      await prefs.setString(RoomWatcher.storageKey, jsonEncode(saved));
      gateway.reorder = true;
      final reads = budget.clamp(0, 13);
      final passes = reads == 0 ? 2 : (13 / reads).ceil();
      final seen = <String>{};
      for (var pass = 0; pass < passes; pass++) {
        gateway.polled.clear();
        expect(await watcher.tick(gateway), isTrue);
        expect(gateway.polled, hasLength(reads));
        expect(gateway.polled.toSet(), hasLength(reads));
        seen.addAll(gateway.polled);
        expect(_savedStates(prefs).keys.toSet(), {
          for (final room in gateway.rooms) RoomWatcher.roomKey('c1', room),
        });
      }
      expect(
        seen,
        reads == 0 ? <String>{} : gateway.rooms.map((r) => r.roomId).toSet(),
      );
      expect(watcher.retryAfter, isNull);
    });
  }

  test('prunes removed and disbanded rooms, not other connections', () async {
    final saved = {
      for (final room in gateway.rooms)
        RoomWatcher.roomKey('c1', room): const RoomWatchState(
          cursor: 7,
        ).toJson(),
      RoomWatcher.roomKey('c2', _room(13)): const RoomWatchState(
        cursor: 99,
      ).toJson(),
    };
    await prefs.setString(RoomWatcher.storageKey, jsonEncode(saved));
    gateway.rooms.removeAt(12);
    gateway.rooms[11] = _room(12, disbanded: true);
    expect(await watcher.tick(gateway), isTrue);
    expect(gateway.polled, hasLength(11));
    expect(gateway.polled, isNot(contains('room-12')));
    expect(watcher.listedRoomIds, isNot(contains('room-13')));
    final states = _savedStates(prefs);
    expect(states.keys, isNot(contains(RoomWatcher.roomKey('c1', _room(12)))));
    expect(states.keys, isNot(contains(RoomWatcher.roomKey('c1', _room(13)))));
    final otherKey = RoomWatcher.roomKey('c2', _room(13));
    expect(states[otherKey], saved[otherKey]);
    gateway.rooms.clear();
    gateway.polled.clear();
    expect(await watcher.tick(gateway), isTrue);
    expect(gateway.polled, isEmpty);
    expect(watcher.views, isEmpty);
    expect(watcher.listedRoomIds, isEmpty);
    expect(watcher.anyWorking, isFalse);
    expect(_savedStates(prefs), {otherKey: saved[otherKey]});
    gateway.rooms.addAll([for (var i = 1; i <= 13; i++) _room(i)]);
    expect(await watcher.tick(gateway), isTrue);
    expect(gateway.polled, [for (var i = 1; i <= 12; i++) 'room-$i']);
  });

  test(
    'membership changes resume bounded fair reads after stabilization',
    () async {
      gateway.reorder = true;
      expect(await watcher.tick(gateway), isTrue);
      gateway.rooms.removeAt(0);
      gateway.rooms.insert(0, _room(14));
      gateway.pendingByRoom['room-14'] = [approvalAction(request: 'apr-14')];
      gateway.polled.clear();
      for (var pass = 0; pass < 2; pass++) {
        expect(await watcher.tick(gateway), isTrue);
      }
      expect(
        gateway.polled.toSet(),
        gateway.rooms.map((r) => r.roomId).toSet(),
      );
      expect(presenter.approvals.single.roomId, 'room-14');
      expect(
        _savedStates(prefs).keys,
        isNot(contains(RoomWatcher.roomKey('c1', _room(1)))),
      );
      // Shrink while the offset is beyond the new list length, then grow again.
      gateway.rooms.removeRange(3, gateway.rooms.length);
      gateway.polled.clear();
      expect(await watcher.tick(gateway), isTrue);
      expect(
        gateway.polled.toSet(),
        gateway.rooms.map((r) => r.roomId).toSet(),
      );
      expect(gateway.polled, hasLength(3));
      gateway.rooms.addAll([for (var i = 15; i <= 24; i++) _room(i)]);
      gateway.polled.clear();
      for (var pass = 0; pass < 2; pass++) {
        expect(await watcher.tick(gateway), isTrue);
      }
      expect(
        gateway.polled.toSet(),
        gateway.rooms.map((r) => r.roomId).toSet(),
      );
      expect(_savedStates(prefs), hasLength(13));
    },
  );

  test(
    'unvisited live state keeps fast cadence until actual removal',
    () async {
      final key = RoomWatcher.roomKey('c1', gateway.rooms.last);
      final live = const RoomWatchState(
        cursor: 7,
        working: true,
        workingSinceMs: 100,
      ).toJson();
      await prefs.setString(RoomWatcher.storageKey, jsonEncode({key: live}));
      expect(await watcher.tick(gateway), isTrue);
      expect(gateway.polled, isNot(contains('room-13')));
      expect(watcher.views, hasLength(12));
      expect(watcher.listedRoomIds, contains('room-13'));
      expect(watcher.anyWorking, isTrue);
      expect(_savedStates(prefs)[key], live);
      gateway.rooms.removeLast();
      expect(await watcher.tick(gateway), isTrue);
      expect(watcher.anyWorking, isFalse);
      expect(_savedStates(prefs).keys, isNot(contains(key)));
    },
  );

  test(
    'listener retains a skipped Live Update and cancels only on removal',
    () async {
      await prefs.setString('last_connection_id', 'c1');
      final dir = await Directory.systemTemp.createTemp('room-paging-faces');
      addTearDown(() => dir.delete(recursive: true));
      var now = DateTime(2026, 9, 26, 12);
      gateway.workingRooms.add('room-13');
      gateway.reorder = true;
      final sink = _LiveSink();
      final monitor = BotModeBackgroundMonitor(
        sink: sink,
        faces: BotFaceBitmapCache(directory: () async => dir),
        now: () => now,
        publish: (_) async {},
        gatewayFor: (_) => gateway,
      );
      addTearDown(monitor.close);
      final targets = [
        SavedConnection.fromMap({
          'id': 'c1',
          'label': 'Fixture',
          'host': '127.0.0.1',
          'port': 1,
          'apiKey': '',
          'useHttps': false,
        }),
      ];
      Future<void> tick() async {
        await monitor.tick(
          prefs: prefs,
          targets: targets,
          notificationsEnabled: true,
        );
        now = now.add(const Duration(seconds: 30));
      }

      final tag = RichNotificationIds.roomTag('c1', 'room-13');
      // Baseline room 13 on pass two, post its live card on pass three.
      for (var pass = 0; pass < 3; pass++) {
        await tick();
      }
      expect(sink.liveTags, contains(tag));
      sink.cancelled.clear();
      var skipped = false;
      for (var pass = 0; pass < 13; pass++) {
        gateway.polled.clear();
        await tick();
        expect(gateway.polled, hasLength(12));
        if (!gateway.polled.contains('room-13')) {
          skipped = true;
          break;
        }
      }
      expect(skipped, isTrue);
      expect(sink.cancelled, isNot(contains(tag)));
      gateway.rooms.removeWhere((r) => r.roomId == 'room-13');
      await tick();
      expect(sink.cancelled, contains(tag));
    },
  );
}

Map<String, dynamic> _savedStates(SharedPreferences prefs) =>
    jsonDecode(prefs.getString(RoomWatcher.storageKey)!)
        as Map<String, dynamic>;

final class _RecordingPresenter implements RoomNoticePresenter {
  final approvals = <({String roomId, String requestId})>[];

  @override
  Future<void> present(
    String connId,
    HostedGroupRoom room,
    List<RoomNotice> notices,
  ) async {
    for (final notice in notices.whereType<RoomApprovalNotice>()) {
      approvals.add((roomId: room.roomId, requestId: notice.action.requestId));
    }
  }
}

final class _ThirteenRoomGateway implements BotModeGateway {
  final rooms = [for (var i = 1; i <= 13; i++) _room(i)];
  final pendingByRoom = <String, List<Map<String, dynamic>>>{};
  final polled = <String>[];
  final failures = <String>{};
  bool logRecovers = false;
  bool reorder = false;
  final workingRooms = <String>{};
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
    if (!reorder || rooms.isEmpty) return [...rooms];
    // An offset-only scheduler without stable identities repeatedly misses
    // room 13 under this adversarial (but valid) server-side ordering.
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
      room: rooms.singleWhere((room) => room.roomId == roomId),
      driverStatus: driver(
        working: workingRooms.contains(roomId),
        pending: pendingByRoom[roomId] ?? const [],
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
    if (!logRecovers) throw StateError('log unavailable');
    final event = (EventSeq()..seq = sinceSeq).user('recovered')
      ..['room_id'] = roomId;
    return HostedGroupLogPage.fromJson(
      {
        'events': [event],
        'cursor': 7,
        'latest_seq': 7,
        'has_more': false,
        'authority': {'gateway_id': 'gw-home-1', 'epoch': 2},
      },
      expectedRoomId: roomId,
      sinceSeq: sinceSeq,
    );
  }

  @override
  Future<List<AgentProfile>> listProfiles() async => const [];

  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HostedGroupRoom _room(int number, {bool disbanded = false}) =>
    HostedGroupRoom.fromJson({
      'room_id': 'room-$number',
      'name': 'Room $number',
      'members': const [],
      'authority_gateway_id': 'gw-home-1',
      'authority_epoch': 2,
      'revision': 1,
      'created_at': 1790000000.0,
      'updated_at': 1790000500.0,
      'latest_seq': 7,
      if (disbanded) 'disbanded_at': 1790000600.0,
    });

final class _LiveSink implements RichNotificationSink {
  final liveTags = <String>[];
  final cancelled = <String>[];

  @override
  Future<void> cancel({required int id, String? tag}) async {
    if (id == RichNotificationIds.live && tag != null) cancelled.add(tag);
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {
    liveTags.add(args['tag']! as String);
  }

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
