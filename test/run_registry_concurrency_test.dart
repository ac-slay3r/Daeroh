import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

RunRecord _record(String id, {String profile = 'default', double at = 1}) =>
    RunRecord(
      runId: id,
      prompt: id,
      createdAt: at,
      lastStatus: 'queued',
      profile: profile,
    );

class _WriteGate {
  final entered = Completer<void>();
  final release = Completer<bool>();
}

class _ReadGate {
  final entered = Completer<void>();
  final release = Completer<void>();
}

class _ControlledStore extends InMemorySharedPreferencesStore {
  _ControlledStore() : super.empty();

  final writes = <String>[];
  final readGates = <_ReadGate>[];
  _WriteGate? nextWrite;
  bool failRead = false;

  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('read failed');
    final gate = readGates.isEmpty ? null : readGates.removeAt(0);
    final snapshot = Map<String, Object>.of(await super.getAll());
    if (gate != null) {
      gate.entered.complete();
      await gate.release.future;
    }
    return snapshot;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(key);
    final gate = nextWrite;
    nextWrite = null;
    if (gate != null) {
      gate.entered.complete();
      if (!await gate.release.future) return false;
    }
    return super.setValue(valueType, key, value);
  }

  Future<List<RunRecord>> persisted(String connection) async {
    final raw = (await getAll())['flutter.runs_$connection'] as String?;
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((value) => RunRecord.fromJson(value as Map<String, dynamic>))
        .toList();
  }
}

void main() {
  late SharedPreferences prefs;
  late _ControlledStore store;
  late RunRegistry a;
  late RunRegistry b;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = _ControlledStore();
    SharedPreferencesStorePlatform.instance = store;
    prefs = await SharedPreferences.getInstance();
    a = await RunRegistry.load(prefs, 'one');
    b = await RunRegistry.load(prefs, 'one');
  });

  tearDown(() => SharedPreferences.setMockInitialValues({}));

  test(
    'two instances merge adds, statuses and removals with fresh reads',
    () async {
      await a.add(_record('shared', profile: ' Alpha '));
      await b.add(_record('shared', profile: 'beta', at: 2));
      await a.update('shared', profile: 'Alpha', lastStatus: 'completed');
      await b.update('shared', profile: 'beta', output: 'beta output');
      expect(b.records.first.profile, 'beta');
      expect(b.records.last.lastStatus, 'completed');
      expect(a.records.first.output, 'beta output');
      expect(a.records.every((r) => r.connId == 'one'), isTrue);
      a.records.clear(); // Returned lists cannot mutate shared state.
      expect(b.records, hasLength(2));
      await b.remove('shared', profile: 'beta');
      expect(a.records.single.profile, 'Alpha');
      expect((await store.persisted('one')).single.lastStatus, 'completed');
    },
  );

  test(
    'delayed add serializes a second add and patch without losing fields',
    () async {
      final gate = store.nextWrite = _WriteGate();
      final first = a.add(_record('first'));
      await gate.entered.future;
      final second = b.add(_record('second', at: 2));
      final update = b.update('first', lastStatus: 'completed', output: 'done');
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, hasLength(1));
      expect(a.records, isEmpty); // No optimistic publication.
      expect(b.records, isEmpty);
      gate.release.complete(true);
      await Future.wait([first, second, update]);
      expect(a.records.map((r) => r.runId), ['second', 'first']);
      expect(b.records.last.lastStatus, 'completed');
      await a.update('first', progressLabel: 'final step');
      expect(b.records.last.output, 'done');
      expect((await store.persisted('one')).first.progressLabel, 'final step');
    },
  );

  for (final clearFirst in [true, false]) {
    test(
      'delayed clear/update ordering clearFirst=$clearFirst never resurrects',
      () async {
        await a.add(_record('old'));
        final gate = store.nextWrite = _WriteGate();
        final first = clearFirst
            ? a.clear()
            : a.update('old', lastStatus: 'completed');
        await gate.entered.future;
        final count = store.writes.length;
        final second = clearFirst
            ? b.update('old', lastStatus: 'failed')
            : b.clear();
        final newRun = a.add(_record('new', at: 2));
        await Future<void>.delayed(Duration.zero);
        expect(store.writes, hasLength(count));
        gate.release.complete(true);
        await Future.wait([first, second, newRun]);
        expect(a.records.single.runId, 'new');
        expect(b.records.single.runId, 'new');
        expect((await store.persisted('one')).single.runId, 'new');
      },
    );
  }

  test(
    'delayed remove then stale update cannot restore deleted owner',
    () async {
      await a.add(_record('same', profile: 'alpha'));
      await b.add(_record('same', profile: 'beta'));
      final gate = store.nextWrite = _WriteGate();
      final remove = a.remove('same', profile: 'alpha');
      await gate.entered.future;
      final update = b.update('same', profile: 'alpha', lastStatus: 'failed');
      gate.release.complete(true);
      await Future.wait([remove, update]);
      expect(a.records.single.profile, 'beta');
      expect((await store.persisted('one')).single.profile, 'beta');
    },
  );

  test('ownership repair queues with mutation and another load', () async {
    await prefs.setString('runs_one', jsonEncode([_record('legacy').toJson()]));
    final gate = store.nextWrite = _WriteGate();
    final load = RunRegistry.load(prefs, 'one');
    await gate.entered.future;
    final clear = b.clear();
    final reload = RunRegistry.load(prefs, 'one');
    final add = a.add(_record('new', profile: 'beta'));
    final count = store.writes.length;
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, hasLength(count));
    gate.release.complete(true);
    await Future.wait<Object?>([load, clear, reload, add]);
    expect(a.records.single.runId, 'new');
    expect((await load).records.single.runId, 'new');
    expect((await reload).records.single.connId, 'one');
    expect((await store.persisted('one')).single.profile, 'beta');
  });

  test(
    'another key proceeds during a delayed write without corrupting either',
    () async {
      final other = await RunRegistry.load(prefs, 'two');
      final gate = store.nextWrite = _WriteGate();
      final pending = a.add(_record('one'));
      await gate.entered.future;
      await other.add(_record('two'));
      await other.update('two', lastStatus: 'completed');
      expect(other.records.single.lastStatus, 'completed');
      expect(a.records, isEmpty);
      gate.release.complete(true);
      await pending;
      await b.update('one', output: 'survived other reloads');
      expect(a.records.single.output, 'survived other reloads');
      await a.clear();
      expect(b.records, isEmpty);
      expect(other.records.single.lastStatus, 'completed');
      expect((await store.persisted('two')).single.connId, 'two');
    },
  );

  test(
    'reversed cross-key reload snapshots cannot roll back a newer status',
    () async {
      await a.add(_record('kept'));
      final write = store.nextWrite = _WriteGate();
      final update = a.update('kept', lastStatus: 'completed');
      await write.entered.future;
      final oldRead = _ReadGate();
      final freshRead = _ReadGate();
      store.readGates.addAll([oldRead, freshRead]);
      final otherLoad = RunRegistry.load(prefs, 'two');
      await oldRead
          .entered
          .future; // Captured 'queued' before the write commits.
      write.release.complete(true);
      await update;
      final add = b.add(_record('new', at: 2));
      await Future<void>.delayed(Duration.zero);
      if (freshRead.entered.isCompleted) {
        // An unguarded store can complete fresh then stale snapshots in the same
        // microtask turn, replacing the global cache before the fresh caller reads.
        freshRead.release.complete();
        oldRead.release.complete();
      } else {
        // Correctly serialized reload/read sections prevent that interleaving.
        oldRead.release.complete();
        await freshRead.entered.future;
        freshRead.release.complete();
      }
      await Future.wait<Object?>([otherLoad, add]);
      expect(a.records.last.lastStatus, 'completed');
      expect((await store.persisted('one')).first.lastStatus, 'completed');
      expect(b.records.first.runId, 'new');
    },
  );

  test('interleaved instances enforce max 50 and newest-first order', () async {
    await Future.wait([
      for (var i = 0; i < 60; i++)
        (i.isEven ? a : b).add(_record('run-$i', at: i.toDouble())),
    ]);
    expect(a.records, hasLength(50));
    expect(b.records.first.runId, 'run-59');
    expect(b.records.last.runId, 'run-10');
    expect(await store.persisted('one'), hasLength(50));
  });

  for (final throws in [false, true]) {
    test(
      'failed write throws=$throws is hidden and does not poison queued mutation',
      () async {
        await a.add(_record('kept'));
        final gate = store.nextWrite = _WriteGate();
        final failed = a.clear();
        final assertion = expectLater(failed, throwsStateError);
        await gate.entered.future;
        final queued = b.add(_record('new', at: 2));
        expect(b.records.single.runId, 'kept');
        if (throws) {
          gate.release.completeError(StateError('write failed'));
        } else {
          gate.release.complete(false);
        }
        await assertion;
        await queued;
        expect(a.records.map((r) => r.runId), ['new', 'kept']);
        expect(await store.persisted('one'), hasLength(2));
      },
    );

    test(
      'failed repair throws=$throws rejects load and permits retry',
      () async {
        await prefs.setString(
          'runs_one',
          jsonEncode([_record('legacy').toJson()]),
        );
        final gate = store.nextWrite = _WriteGate();
        final failed = RunRegistry.load(prefs, 'one');
        final assertion = expectLater(failed, throwsStateError);
        await gate.entered.future;
        if (throws) {
          gate.release.completeError(StateError('repair failed'));
        } else {
          gate.release.complete(false);
        }
        await assertion;
        expect(a.records, isEmpty);
        final retried = await RunRegistry.load(prefs, 'one');
        expect(retried.records.single.connId, 'one');
        expect(a.records.single.connId, 'one');
        expect((await store.persisted('one')).single.connId, 'one');
      },
    );
  }

  test(
    'read failure does not overwrite persisted data or poison the queue',
    () async {
      await a.add(_record('kept'));
      store.failRead = true;
      await expectLater(b.clear(), throwsStateError);
      expect(a.records.single.runId, 'kept');
      store.failRead = false;
      await b.update('kept', lastStatus: 'completed');
      expect((await store.persisted('one')).single.lastStatus, 'completed');
    },
  );
}
