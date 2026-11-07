import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_notification_presenter.dart';
import 'package:hermes_android/core/services/notifications/notification_event_ledger.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../bots/room/room_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late NotificationEventLedger ledger;
  late _Gateway gateway;
  late _Presenter presenter;
  late DateTime now;
  final releases = <String>[];
  var releaseFails = false;

  Future<bool> claim(String c, String r, String k) =>
      ledger.claim(connId: c, profile: 'rooms', objectId: r, eventKind: k);
  Future<void> release(String c, String r, String k) async {
    releases.add('$c/$r/$k');
    if (releaseFails) throw StateError('fixture release unavailable');
    await ledger.release(
      connId: c,
      profile: 'rooms',
      objectId: r,
      eventKind: k,
    );
  }

  RoomWatcher watcher({
    RoomNoticePresenter? using,
    RoomNoticeClaim? claiming,
  }) => RoomWatcher(
    connId: 'fixture',
    prefs: prefs,
    presenter: using ?? presenter,
    claim: claiming ?? claim,
    release: release,
    now: () => now,
  );
  Map<String, dynamic> states() =>
      jsonDecode(prefs.getString(RoomWatcher.storageKey)!)
          as Map<String, dynamic>;
  Set<String> claims() => {
    for (final e in NotificationEventLedger.decodeEntries(
      prefs.getString(NotificationEventLedger.storageKey),
    ))
      '${e['c']}/${e['p']}/${e['o']}/${e['k']}',
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({'app_locale': 'en'});
    prefs = await SharedPreferences.getInstance();
    ledger = NotificationEventLedger(prefs);
    gateway = _Gateway();
    presenter = _Presenter();
    now = DateTime(2026);
    releases.clear();
    releaseFails = false;
  });

  for (final throws in [false, true]) {
    for (final restart in [false, true]) {
      test(
        'journal create failure releases claim; throw=$throws restart=$restart',
        () async {
          final store = _FailingJournalStore(throws: throws);
          SharedPreferencesStorePlatform.instance = store;
          SharedPreferences.resetStatic();
          prefs = await SharedPreferences.getInstance();
          ledger = NotificationEventLedger(prefs);
          final first = watcher();
          expect(await first.tick(gateway), isTrue);
          await prefs.reload();
          expect(claims(), {'fixture/rooms/room-2/approval:a'});
          expect(releases, ['fixture/room-1/approval:a']);
          expect(
            states(),
            isNot(
              contains(RoomWatcher.roomKey('fixture', gateway.rooms.first)),
            ),
          );
          store.failJournal = false;
          final retry = restart ? watcher() : first;
          for (var i = 0; i < 3; i++) {
            expect(await retry.tick(gateway), isTrue);
          }
          expect(await watcher().tick(gateway), isTrue);
          expect(presenter.delivered, [
            'room-2/approval:a',
            'room-1/approval:a',
          ]);
        },
      );
    }
    for (final restart in [false, true]) {
      test(
        'journal and release failure retains obligation; throw=$throws restart=$restart',
        () async {
          final store = _FailingJournalStore(throws: throws);
          SharedPreferencesStorePlatform.instance = store;
          SharedPreferences.resetStatic();
          prefs = await SharedPreferences.getInstance();
          ledger = NotificationEventLedger(prefs);
          releaseFails = true;
          final first = watcher();
          expect(await first.tick(gateway), isTrue);
          expect(await first.tick(gateway), isTrue);
          await prefs.reload();
          expect(claims(), hasLength(2));
          expect(presenter.attempts.where((r) => r == 'room-1'), hasLength(1));
          expect(
            states(),
            isNot(
              contains(RoomWatcher.roomKey('fixture', gateway.rooms.first)),
            ),
          );
          // Persist the retained obligation before simulating process loss.
          store.failJournal = false;
          expect(await first.tick(gateway), isTrue);
          await prefs.reload();
          expect(
            prefs.getKeys().where((k) => k.startsWith('bg_room_release_v1:')),
            hasLength(1),
          );
          releaseFails = false;
          expect(await (restart ? watcher() : first).tick(gateway), isTrue);
          expect(await watcher().tick(gateway), isTrue);
          expect(presenter.delivered, [
            'room-2/approval:a',
            'room-1/approval:a',
          ]);
          expect(
            releases.every((k) => k == 'fixture/room-1/approval:a'),
            isTrue,
          );
        },
      );
    }
  }

  for (final restart in [false, true]) {
    test('throwing first presenter retries; restart=$restart', () async {
      final first = watcher();
      expect(await first.tick(gateway), isTrue); // other room succeeds
      expect(
        states(),
        isNot(contains(RoomWatcher.roomKey('fixture', gateway.rooms.first))),
      );
      expect(claims(), {'fixture/rooms/room-2/approval:a'});
      expect(releases, ['fixture/room-1/approval:a']);
      final retry = restart ? watcher() : first;
      expect(await retry.tick(gateway), isTrue);
      expect(presenter.delivered, ['room-2/approval:a', 'room-1/approval:a']);
      expect(claims(), {
        'fixture/rooms/room-1/approval:a',
        'fixture/rooms/room-2/approval:a',
      });
      // Lose watcher state only: the durable ledger still suppresses success.
      await prefs.remove(RoomWatcher.storageKey);
      expect(await watcher().tick(gateway), isTrue);
      expect(presenter.delivered, hasLength(2));
    });
  }

  test(
    'failed release is retried before claims, including after restart',
    () async {
      releaseFails = true;
      expect(await watcher().tick(gateway), isTrue);
      expect(claims(), hasLength(2));
      expect(await watcher().tick(gateway), isTrue);
      expect(presenter.attempts.where((r) => r == 'room-1'), hasLength(1));
      expect(
        states(),
        isNot(contains(RoomWatcher.roomKey('fixture', gateway.rooms.first))),
      );
      releaseFails = false;
      await prefs.reload();
      expect(await watcher().tick(gateway), isTrue);
      expect(presenter.delivered, ['room-2/approval:a', 'room-1/approval:a']);
      expect(
        prefs.getKeys().where((k) => k.startsWith('bg_room_release_v1:')),
        isEmpty,
      );
    },
  );

  test(
    'preexisting claims and other connection/profile claims are untouched',
    () async {
      gateway.pending = [
        approvalAction(request: 'old'),
        approvalAction(request: 'a'),
      ];
      expect(await claim('fixture', 'room-1', 'approval:old'), isTrue);
      for (final scope in [('other', 'rooms'), ('fixture', 'other')]) {
        await ledger.claim(
          connId: scope.$1,
          profile: scope.$2,
          objectId: 'room-1',
          eventKind: 'approval:a',
        );
      }
      expect(await watcher().tick(gateway), isTrue);
      expect(releases, ['fixture/room-1/approval:a']);
      expect(
        claims(),
        containsAll([
          'fixture/rooms/room-1/approval:old',
          'other/rooms/room-1/approval:a',
          'fixture/other/room-1/approval:a',
          'fixture/rooms/room-2/approval:old',
          'fixture/rooms/room-2/approval:a',
        ]),
      );
      expect(await watcher().tick(gateway), isTrue);
      expect(
        presenter.delivered.where((k) => k == 'room-1/approval:old'),
        isEmpty,
      );
      expect(
        presenter.delivered.where((k) => k == 'room-1/approval:a'),
        hasLength(1),
      );
    },
  );

  test(
    'failed recovery-journal removal cannot be hidden by the cache',
    () async {
      final store = _FailingRemoveStore();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      prefs = await SharedPreferences.getInstance();
      ledger = NotificationEventLedger(prefs);
      final first = watcher();
      expect(await first.tick(gateway), isTrue);
      expect(await first.tick(gateway), isTrue);
      expect(presenter.attempts.where((r) => r == 'room-1'), hasLength(1));
      expect(
        states(),
        isNot(contains(RoomWatcher.roomKey('fixture', gateway.rooms.first))),
      );
      store.failRemove = false;
      expect(await first.tick(gateway), isTrue);
      expect(presenter.delivered, ['room-2/approval:a', 'room-1/approval:a']);
      expect(await watcher().tick(gateway), isTrue);
      expect(presenter.delivered, hasLength(2));
    },
  );

  test(
    'claim failure releases earlier acquisitions without presenting',
    () async {
      gateway.pending = [
        approvalAction(request: 'a'),
        approvalAction(request: 'b'),
      ];
      final first = watcher(
        claiming: (c, r, k) async {
          if (r == 'room-1' && k == 'approval:b') {
            throw StateError('fixture claim');
          }
          return claim(c, r, k);
        },
      );
      expect(await first.tick(gateway), isTrue);
      expect(releases, ['fixture/room-1/approval:a']);
      expect(presenter.attempts, ['room-2']);
      presenter.failFirst = false;
      expect(await watcher().tick(gateway), isTrue);
      expect(
        presenter.delivered.where((k) => k.startsWith('room-1/')),
        hasLength(2),
      );
    },
  );

  test(
    'log cursor stays put on failure and retry delivers the missed mention',
    () async {
      gateway.pending = [];
      final first = watcher();
      expect(await first.tick(gateway), isTrue);
      gateway.events = [
        EventSeq().member('m-builder', 'builder', '@user help', 'd'),
      ];
      expect(await first.tick(gateway), isTrue);
      final key = RoomWatcher.roomKey('fixture', gateway.rooms.first);
      expect(RoomWatchState.fromJson(states()[key]).cursor, 0);
      expect(await watcher().tick(gateway), isTrue);
      expect(RoomWatchState.fromJson(states()[key]).cursor, 1);
      expect(
        presenter.delivered.where(
          (k) => k == 'room-1/mention:message.member-1',
        ),
        hasLength(1),
      );
      expect(gateway.logSince.where((e) => e == 'room-1:0'), hasLength(2));
    },
  );

  test(
    'all-room presentation failure backs off without advancing state',
    () async {
      gateway.onlyFirst = true;
      final first = watcher();
      expect(await first.tick(gateway), isFalse);
      expect(first.retryAfter, const Duration(minutes: 1));
      expect(await first.tick(gateway), isFalse);
      expect(presenter.attempts, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      expect(await first.tick(gateway), isTrue);
      expect(first.retryAfter, isNull);
      expect(presenter.delivered, ['room-1/approval:a']);
    },
  );

  for (final reject in [false, true]) {
    for (final journalThrows in [null, false, true]) {
      test(
        'real presenter partial batch retains only delivered claim; reject=$reject journalThrows=$journalThrows',
        () async {
          if (journalThrows != null) {
            SharedPreferencesStorePlatform.instance = _FailingJournalStore(
              throws: journalThrows,
            );
            SharedPreferences.resetStatic();
            prefs = await SharedPreferences.getInstance();
            ledger = NotificationEventLedger(prefs);
          }
          final dir = await Directory.systemTemp.createTemp(
            'claim-retry-faces',
          );
          addTearDown(() => dir.delete(recursive: true));
          gateway.onlyFirst = true;
          gateway.pending = [
            approvalAction(request: 'a'),
            approvalAction(request: 'b'),
          ];
          final sink = _Sink(reject: reject);
          final rich = RichRoomNoticePresenter(
            sink: sink,
            prefs: prefs,
            faces: BotFaceBitmapCache(directory: () async => dir),
          );
          expect(await watcher(using: rich).tick(gateway), isFalse);
          expect(sink.delivered, ['a']);
          expect(claims(), {'fixture/rooms/room-1/approval:a'});
          expect(releases, ['fixture/room-1/approval:b']);
          expect(states(), isEmpty);
          expect(await watcher(using: rich).tick(gateway), isTrue);
          expect(sink.delivered, ['a', 'b']);
          expect(claims(), hasLength(2));
          await prefs.remove(RoomWatcher.storageKey);
          expect(await watcher(using: rich).tick(gateway), isTrue);
          expect(sink.delivered, ['a', 'b']);
        },
      );
    }
  }
}

final class _FailingJournalStore extends InMemorySharedPreferencesStore {
  _FailingJournalStore({required this.throws}) : super.empty();
  final bool throws;
  bool failJournal = true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failJournal && key.startsWith('flutter.bg_room_release_v1:')) {
      if (throws) throw StateError('fixture journal unavailable');
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

final class _FailingRemoveStore extends InMemorySharedPreferencesStore {
  _FailingRemoveStore() : super.empty();
  bool failRemove = true;

  @override
  Future<bool> remove(String key) async {
    if (failRemove && key.startsWith('flutter.bg_room_release_v1:')) {
      return false;
    }
    return super.remove(key);
  }
}

final class _Presenter implements RoomNoticePresenter {
  bool failFirst = true;
  final attempts = <String>[];
  final delivered = <String>[];
  @override
  Future<void> present(
    String c,
    HostedGroupRoom room,
    List<RoomNotice> notices,
  ) async {
    attempts.add(room.roomId);
    if (failFirst &&
        room.roomId == 'room-1' &&
        attempts.where((r) => r == 'room-1').length == 1) {
      throw StateError('fixture presenter failed before delivery');
    }
    delivered.addAll(
      notices
          .where((n) => n.dedupeKey != null)
          .map((n) => '${room.roomId}/${n.dedupeKey}'),
    );
  }
}

final class _Gateway implements BotModeGateway {
  bool onlyFirst = false;
  List<Map<String, dynamic>> pending = [approvalAction(request: 'a')];
  List<Map<String, dynamic>> events = [];
  final logSince = <String>[];
  List<HostedGroupRoom> get rooms => [
    for (var i = 1; i <= (onlyFirst ? 1 : 2); i++)
      HostedGroupRoom.fromJson({
        'room_id': 'room-$i',
        'name': 'Fixture $i',
        'members': [memberJson('m-builder', 'builder')],
        'authority_gateway_id': 'gw-fixture',
        'authority_epoch': 2,
        'revision': 1,
        'created_at': 1790000000.0,
        'updated_at': 1790000500.0,
        'latest_seq': events.length,
      }),
  ];
  @override
  Future<GroupsCapabilities> groupCapabilities() async =>
      GroupsCapabilities.tryParse(
        {
          'protocol_version': 1,
          'driver': true,
          'max_log_limit': 500,
          'methods': [for (final m in GroupMethod.values) m.wire],
        },
        connectionId: 'fixture',
        generation: 1,
      )!;
  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) async =>
      rooms;
  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) async => (
    room: rooms.singleWhere((r) => r.roomId == roomId),
    driverStatus: driver(pending: pending),
  );
  @override
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    logSince.add('$roomId:$sinceSeq');
    return buildLog(
      events.where((e) => (e['seq'] as int) > sinceSeq).toList(),
      sinceSeq: sinceSeq,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sink implements RichNotificationSink {
  _Sink({required this.reject});
  final bool reject;
  var failed = false;
  final delivered = <String>[];
  @override
  Future<bool> postConversation(Map<String, Object?> args) async {
    final action = NotificationActionPayload.tryParse(
      args['actionPayload'] as String,
    )!;
    if (action.requestId == 'b' && !failed) {
      failed = true;
      if (reject) return false;
      throw StateError('fixture second approval failed');
    }
    delivered.add(action.requestId!);
    return true;
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {}
  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {}
  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
}
