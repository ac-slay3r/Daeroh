import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Registro local de ejecuciones (/v1/runs) lanzadas desde esta app.
///
/// El gateway NO expone listado de runs (GET /v1/runs → 405, verificado
/// contra api_server.py del upstream): los estados viven en memoria del
/// servidor indexados por run_id y se barren al terminar. La única forma
/// honesta de tener una lista en el móvil es recordar los run_id que esta
/// app creó. Clave: `runs_<connectionId>`.
class RunRecord {
  final String runId;
  final String prompt;
  final String? sessionId;
  final double createdAt; // epoch seconds

  /// Último estado conocido (queued/running/waiting_for_approval/completed/
  /// failed/cancelled) o `expired` cuando el gateway ya no lo conserva.
  final String lastStatus;
  final String? output;
  final String? error;

  // Campos opcionales añadidos en Fase 1 del Task Center.
  // Todos son null en registros antiguos; fromJson los ignora si no están.

  /// Etiqueta del último paso visible (p.ej. "tool: read_file"). Solo se
  /// rellena cuando hay eventos SSE en curso; null si el run no ha empezado
  /// o ya terminó.
  final String? progressLabel;

  /// Tipo del último evento SSE procesado (p.ej. "tool.started"). Útil para
  /// depuración y para que la pantalla sepa qué se vio por última vez.
  final String? lastEvent;

  /// Epoch seconds del último cambio de estado registrado localmente.
  final double? updatedAt;

  /// ID de la conexión desde la que se lanzó este run. Null en registros
  /// antiguos que no lo guardaron (backward-compatible: fromJson lo ignora
  /// si no está presente).
  final String? connId;

  /// Perfil propietario del runtime. Los registros legacy que no lo guardaban
  /// pertenecen a `default` para mantener una migración determinista.
  final String profile;

  const RunRecord({
    required this.runId,
    required this.prompt,
    required this.createdAt,
    required this.lastStatus,
    this.sessionId,
    this.output,
    this.error,
    this.progressLabel,
    this.lastEvent,
    this.updatedAt,
    this.connId,
    this.profile = 'default',
  });

  RunRecord copyWith({
    String? lastStatus,
    String? output,
    String? error,
    String? progressLabel,
    String? lastEvent,
    double? updatedAt,
    String? connId,
    String? profile,
  }) => RunRecord(
    runId: runId,
    prompt: prompt,
    sessionId: sessionId,
    createdAt: createdAt,
    lastStatus: lastStatus ?? this.lastStatus,
    output: output ?? this.output,
    error: error ?? this.error,
    progressLabel: progressLabel ?? this.progressLabel,
    lastEvent: lastEvent ?? this.lastEvent,
    updatedAt: updatedAt ?? this.updatedAt,
    connId: connId ?? this.connId,
    profile: profile ?? this.profile,
  );

  bool get isTerminal => const {
    'completed',
    'failed',
    'cancelled',
    'expired',
  }.contains(lastStatus);

  Map<String, dynamic> toJson() => {
    'run_id': runId,
    'prompt': prompt,
    if (sessionId != null) 'session_id': sessionId,
    'created_at': createdAt,
    'last_status': lastStatus,
    if (output != null) 'output': output,
    if (error != null) 'error': error,
    if (progressLabel != null) 'progress_label': progressLabel,
    if (lastEvent != null) 'last_event': lastEvent,
    if (updatedAt != null) 'updated_at': updatedAt,
    if (connId != null) 'conn_id': connId,
    'profile': profile,
  };

  factory RunRecord.fromJson(Map<String, dynamic> json) => RunRecord(
    runId: json['run_id'] ?? '',
    prompt: json['prompt'] ?? '',
    sessionId: json['session_id'] as String?,
    createdAt: (json['created_at'] as num?)?.toDouble() ?? 0,
    lastStatus: json['last_status'] ?? 'unknown',
    output: json['output'] as String?,
    error: json['error'] as String?,
    progressLabel: json['progress_label'] as String?,
    lastEvent: json['last_event'] as String?,
    updatedAt: (json['updated_at'] as num?)?.toDouble(),
    connId: json['conn_id'] as String?,
    profile: switch ((json['profile'] ?? '').toString().trim()) {
      final value when value.isNotEmpty => value,
      _ => 'default',
    },
  );
}

class RunRegistry {
  static const _prefix = 'runs_';
  static const _maxRecords = 50;

  // SharedPreferences is a singleton within the app isolate. Scope queues to
  // that store and key, not to a screen/registry instance. Other connections
  // remain independent; cross-isolate/native writers require another protocol.
  static final _stores = Expando<Map<String, _RunRegistryState>>();

  final SharedPreferences _prefs;
  final String _key;
  final String _connectionId;
  final _RunRegistryState _state;

  RunRegistry._(this._prefs, this._key, this._connectionId, this._state);

  static Future<RunRegistry> load(
    SharedPreferences prefs,
    String connectionId,
  ) async {
    final key = '$_prefix$connectionId';
    final states = _stores[prefs] ??= {};
    final state = states.putIfAbsent(key, _RunRegistryState.new);
    final registry = RunRegistry._(prefs, key, connectionId, state);
    await state.serialize(() async {
      await prefs.reload();
      final records = registry._read();
      if (records.any((record) => record.connId != connectionId)) {
        await registry._persist(registry._owned(records));
      } else {
        state.records = records;
      }
    });
    return registry;
  }

  List<RunRecord> _read() {
    final raw = _prefs.getString(_key);
    var records = <RunRecord>[];
    if (raw != null) {
      try {
        records = (jsonDecode(raw) as List)
            .whereType<Map<String, dynamic>>()
            .map(RunRecord.fromJson)
            .where((r) => r.runId.isNotEmpty)
            .toList();
      } catch (e) {
        debugPrint(
          '[run-registry] excepción silenciada (fallback: records = []): $e',
        );
        records = [];
      }
    }
    return records;
  }

  List<RunRecord> _owned(List<RunRecord> records) => records
      .map(
        (record) => record.connId == _connectionId
            ? record
            : record.copyWith(connId: _connectionId),
      )
      .toList();

  /// Más reciente primero. All instances see the last successful load/write;
  /// pending or failed optimistic SharedPreferences cache writes stay hidden.
  List<RunRecord> get records {
    final sorted = [..._state.records]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted;
  }

  Future<void> add(RunRecord record) => _mutate((records) {
    final profile = _normalizeRunProfile(record.profile);
    final owned = record.copyWith(connId: _connectionId, profile: profile);
    records.removeWhere(
      (r) => r.runId == owned.runId && r.profile == owned.profile,
    );
    records.add(owned);
    // Mantener el registro acotado: los más antiguos salen primero.
    if (records.length > _maxRecords) {
      records.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      records.removeRange(0, records.length - _maxRecords);
    }
  });

  Future<void> update(
    String runId, {
    String profile = 'default',
    String? lastStatus,
    String? output,
    String? error,
    String? progressLabel,
    String? lastEvent,
    double? updatedAt,
  }) => _mutate((records) {
    final ownerProfile = _normalizeRunProfile(profile);
    final i = records.indexWhere(
      (r) => r.runId == runId && r.profile == ownerProfile,
    );
    if (i < 0) return;
    records[i] = records[i].copyWith(
      lastStatus: lastStatus,
      output: output,
      error: error,
      progressLabel: progressLabel,
      lastEvent: lastEvent,
      updatedAt: updatedAt,
    );
  });

  Future<void> remove(String runId, {String profile = 'default'}) => _mutate((
    records,
  ) {
    final ownerProfile = _normalizeRunProfile(profile);
    records.removeWhere((r) => r.runId == runId && r.profile == ownerProfile);
  });

  /// Vacía el historial local de ejecuciones de esta conexión. No afecta al
  /// servidor (que ya no las conserva): solo limpia la lista del móvil.
  Future<void> clear() => _mutate((records) => records.clear());

  Future<void> _mutate(void Function(List<RunRecord>) change) =>
      _state.serialize(() async {
        // Reload after earlier persistence settles, dropping optimistic cache
        // changes left by a false/throwing platform write before reading again.
        await _prefs.reload();
        final records = _owned(_read());
        change(records);
        await _persist(records);
      });

  Future<void> _persist(List<RunRecord> records) async {
    final saved = await _prefs.setString(
      _key,
      jsonEncode(records.map((r) => r.toJson()).toList()),
    );
    if (!saved) throw StateError('RunRegistry persistence failed');
    _state.records = records;
  }
}

class _RunRegistryState {
  List<RunRecord> records = [];
  Future<void> _tail = Future.value();

  Future<void> serialize(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    // Report failure to this caller without poisoning subsequent operations.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

String _normalizeRunProfile(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? 'default' : normalized;
}
