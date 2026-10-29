import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'secure_storage_policy.dart';

/// Immutable owner identity for a saved, display-only server chat preview.
final class ChatPreviewScope {
  final String connectionId;
  final String profile;
  final String sessionId;

  const ChatPreviewScope({
    required this.connectionId,
    required this.profile,
    required this.sessionId,
  });
}

/// Safe, non-authoritative rows rendered while canonical history is loading.
final class ChatPreviewSnapshot {
  final List<Map<String, dynamic>> messages;
  final ({int scope, int profile, int connection, int session})? _admission;

  const ChatPreviewSnapshot(this.messages, [this._admission]);

  bool get isEmpty => messages.isEmpty;
}

/// Encrypted, bounded display cache for remote chat only.
///
/// All platform storage operations share one FIFO. A cleanup advances its
/// in-process publication admission synchronously, then waits for earlier native
/// work before physically deleting keys. Generation state is deliberately not
/// persisted: it fences this process's UI work only; durable deletion is the
/// secure-storage delete itself and valid previews survive an app restart.
final class ChatPreviewStore {
  static const _prefix = 'hermes.chat-preview.v1.';
  static const _maxMessages = 100;
  static const _maxTextCodeUnits = 4096;
  static const _maxSessionBytes = 96 * 1024;
  static const _maxGlobalBytes = 1024 * 1024;
  static final _storage = sharedSecureStorage;

  static final Map<String, int> _generations = <String, int>{};
  static final Map<String, int> _profileGenerations = <String, int>{};
  static final Map<String, int> _connectionGenerations = <String, int>{};
  static final Map<String, int> _sessionGenerations = <String, int>{};
  static final Map<String, int> _revisions = <String, int>{};
  static final Map<String, int> _completedRevisions = <String, int>{};
  static Future<void> _tail = Future<void>.value();
  static bool _tailIdle = true;
  static final ValueNotifier<int> _retirementEvents = ValueNotifier<int>(0);

  /// Changes synchronously whenever a cleanup revokes in-process display
  /// admission. Consumers use this only to discard an already-rendered preview;
  /// it has no bearing on canonical chat or durable turn authority.
  static ValueListenable<int> get retirementEvents => _retirementEvents;

  static String _hex(String value) => value.codeUnits
      .map((unit) => unit.toRadixString(16).padLeft(4, '0'))
      .join();

  static String debugKeyFor(ChatPreviewScope scope) =>
      '$_prefix${_hex(scope.connectionId)}.${_hex(scope.profile)}.${_hex(scope.sessionId)}';

  static String _profileKey(ChatPreviewScope scope) =>
      '${scope.connectionId}\u0000${scope.profile}';

  static ({int scope, int profile, int connection, int session}) _admission(
    ChatPreviewScope scope,
  ) {
    final key = debugKeyFor(scope);
    return (
      scope: _generations[key] ?? 0,
      profile: _profileGenerations[_profileKey(scope)] ?? 0,
      connection: _connectionGenerations[scope.connectionId] ?? 0,
      session: _sessionGenerations[scope.sessionId] ?? 0,
    );
  }

  static bool _sameAdmission(
    ({int scope, int profile, int connection, int session}) a,
    ({int scope, int profile, int connection, int session}) b,
  ) =>
      a.scope == b.scope &&
      a.profile == b.profile &&
      a.connection == b.connection &&
      a.session == b.session;

  static bool _stillAdmitted(
    ChatPreviewScope scope,
    ({int scope, int profile, int connection, int session}) admission,
  ) => _sameAdmission(_admission(scope), admission);

  static int _nextRevision(String key) {
    final revision = (_revisions[key] ?? 0) + 1;
    _revisions[key] = revision;
    return revision;
  }

  /// Serializes reads, writes, enumeration, cleanup and eviction. A completed
  /// tail is recreated by the next caller so its continuation belongs to that
  /// caller's zone; active native work is never reset. Failed operations leave
  /// later work usable while their own caller still receives the real failure.
  static Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_tailIdle) _tail = Future<void>.value();
    _tailIdle = false;
    final prior = _tail;
    final queued = prior.catchError((Object _) {}).then<T>((_) => operation());
    final settled = queued.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tail = settled;
    settled.whenComplete(() {
      if (identical(_tail, settled)) _tailIdle = true;
    });
    return queued;
  }

  static String _identity(Map<String, dynamic> row) {
    final messageId = (row['message_id'] ?? row['_desktopMessageId'])
        ?.toString();
    final rowId = (row['row_id'] ?? row['_desktopRowId'])?.toString();
    if (messageId != null && messageId.isNotEmpty) return 'm:$messageId';
    if (rowId != null && rowId.isNotEmpty) return 'r:$rowId';
    return '';
  }

  static Map<String, dynamic>? _sanitize(Object? raw) {
    if (raw is! Map || raw['_pipeline'] == true || raw['_optimistic'] == true) {
      return null;
    }
    final row = Map<String, dynamic>.from(raw);
    final role = row['role']?.toString().trim().toLowerCase();
    final identity = _identity(row);
    final content = row['content'];
    if ((role != 'user' && role != 'assistant') ||
        identity.isEmpty ||
        content is! String ||
        content.trim().isEmpty) {
      return null;
    }
    final clipped = content.length <= _maxTextCodeUnits
        ? content
        : '${content.substring(0, _maxTextCodeUnits)}…';
    final displayKind = row['display_kind']?.toString();
    return <String, dynamic>{
      'role': role,
      'content': clipped,
      if (row['message_id'] is String) 'message_id': row['message_id'],
      if (row['_desktopMessageId'] is String)
        '_desktopMessageId': row['_desktopMessageId'],
      if (row['row_id'] is String || row['row_id'] is int)
        'row_id': row['row_id'],
      if (row['_desktopRowId'] is String || row['_desktopRowId'] is int)
        '_desktopRowId': row['_desktopRowId'],
      if (row['timestamp'] is num) 'timestamp': row['timestamp'],
      if (displayKind == 'process_complete' ||
          displayKind == 'async_delegation_complete')
        'display_kind': displayKind,
    };
  }

  static List<Map<String, dynamic>> _bound(Iterable<Object?> rows) {
    final byIdentity = <String, Map<String, dynamic>>{};
    for (final raw in rows) {
      final row = _sanitize(raw);
      if (row != null) byIdentity[_identity(row)] = row;
    }
    var result = byIdentity.values.toList(growable: true);
    if (result.length > _maxMessages) {
      result = result.sublist(result.length - _maxMessages);
    }
    while (result.isNotEmpty &&
        utf8.encode(jsonEncode(result)).length > _maxSessionBytes) {
      result.removeAt(0);
    }
    return List<Map<String, dynamic>>.unmodifiable(result);
  }

  static String _encodeBounded(Iterable<Map<String, dynamic>> rows) {
    final messages = _bound(rows).toList(growable: true);
    String encode() => jsonEncode(<String, dynamic>{
      'version': 1,
      'saved_at_ms': DateTime.now().millisecondsSinceEpoch,
      'messages': messages,
    });
    while (messages.isNotEmpty &&
        utf8.encode(encode()).length > _maxSessionBytes) {
      messages.removeAt(0);
    }
    return encode();
  }

  static Future<ChatPreviewSnapshot> load(ChatPreviewScope scope) {
    final admission = _admission(scope);
    final key = debugKeyFor(scope);
    return _enqueue(() async {
      try {
        final raw = await _storage.read(key: key);
        if (!_stillAdmitted(scope, admission) || raw == null || raw.isEmpty) {
          return const ChatPreviewSnapshot([]);
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map ||
            decoded['version'] != 1 ||
            decoded['messages'] is! List) {
          return const ChatPreviewSnapshot([]);
        }
        return ChatPreviewSnapshot(
          _bound(decoded['messages'] as List),
          admission,
        );
      } catch (_) {
        return const ChatPreviewSnapshot([]);
      }
    });
  }

  /// Verifies that a completed device read still belongs to its captured owner.
  static bool isCurrent(ChatPreviewScope scope, ChatPreviewSnapshot snapshot) {
    final admission = snapshot._admission;
    return admission != null && _stillAdmitted(scope, admission);
  }

  static Future<void> save(
    ChatPreviewScope scope,
    Iterable<Map<String, dynamic>> chronologicalRows,
  ) {
    final key = debugKeyFor(scope);
    final admission = _admission(scope);
    final revision = _nextRevision(key);
    final rows = chronologicalRows.toList(growable: false);
    final boundedRows = _bound(rows);
    final encoded = _encodeBounded(boundedRows);
    return _enqueue(() async {
      if (!_stillAdmitted(scope, admission) || _revisions[key] != revision) {
        return;
      }
      try {
        if (boundedRows.isEmpty) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: encoded);
          _completedRevisions[key] = revision;
          if (_stillAdmitted(scope, admission) && _revisions[key] == revision) {
            await _evictOldestUntilBoundInternal(key);
          }
        }
      } catch (_) {
        // Storage availability must not affect canonical chat.
      }
    });
  }

  /// Runs inside [_enqueue]; it must not enqueue nested operations.
  static Future<void> _evictOldestUntilBoundInternal(
    String protectedKey,
  ) async {
    final all = await _storage.readAll();
    var bytes = all.entries
        .where((entry) => entry.key.startsWith(_prefix))
        .fold<int>(0, (sum, entry) => sum + utf8.encode(entry.value).length);
    final keys = all.keys.where((key) => key.startsWith(_prefix)).toList()
      ..sort((a, b) => _savedAt(all[a]!).compareTo(_savedAt(all[b]!)));
    for (final key in keys) {
      if (bytes <= _maxGlobalBytes) return;
      final revision = _revisions[key] ?? 0;
      if (key == protectedKey ||
          (_completedRevisions[key] ?? revision) != revision) {
        continue;
      }
      bytes -= utf8.encode(all[key]!).length;
      _nextRevision(key);
      await _storage.delete(key: key);
    }
  }

  static int _savedAt(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded['saved_at_ms'] is num
          ? (decoded['saved_at_ms'] as num).toInt()
          : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clear(ChatPreviewScope scope) {
    _invalidate(scope);
    _notifyRetirement();
    _nextRevision(debugKeyFor(scope));
    return _enqueue(() => _deleteScopeInternal(scope));
  }

  static Future<void> deleteForProfile(String connectionId, String profile) {
    final profileKey = '$connectionId\u0000$profile';
    _profileGenerations[profileKey] =
        (_profileGenerations[profileKey] ?? 0) + 1;
    _notifyRetirement();
    return _deleteWhere(
      (scope) => scope.connectionId == connectionId && scope.profile == profile,
    );
  }

  static Future<void> deleteForConnection(String connectionId) {
    _connectionGenerations[connectionId] =
        (_connectionGenerations[connectionId] ?? 0) + 1;
    _notifyRetirement();
    return _deleteWhere((scope) => scope.connectionId == connectionId);
  }

  /// Deletes every local preview that names a remotely deleted durable id.
  static Future<void> deleteForSession(String sessionId) {
    _sessionGenerations[sessionId] = (_sessionGenerations[sessionId] ?? 0) + 1;
    _notifyRetirement();
    return _deleteWhere((scope) => scope.sessionId == sessionId);
  }

  static Future<void> _deleteWhere(
    bool Function(ChatPreviewScope scope) matches,
  ) {
    return _enqueue(() async {
      final all = await _storage.readAll();
      for (final key in all.keys.where((key) => key.startsWith(_prefix))) {
        final scope = _scopeFromKey(key);
        if (scope != null && matches(scope)) {
          // The matching admission generation was advanced before this cleanup
          // entered the FIFO. Do not advance this key's revision here: a valid
          // save admitted after that barrier is queued behind this physical
          // delete and must survive it.
          _completedRevisions.remove(key);
          await _storage.delete(key: key);
        }
      }
    });
  }

  static Future<void> _deleteScopeInternal(ChatPreviewScope scope) async {
    await _storage.delete(key: debugKeyFor(scope));
  }

  static ChatPreviewScope? _scopeFromKey(String key) {
    try {
      final pieces = key.substring(_prefix.length).split('.');
      if (pieces.length != 3) return null;
      String decode(String value) => String.fromCharCodes([
        for (var offset = 0; offset < value.length; offset += 4)
          int.parse(value.substring(offset, offset + 4), radix: 16),
      ]);
      return ChatPreviewScope(
        connectionId: decode(pieces[0]),
        profile: decode(pieces[1]),
        sessionId: decode(pieces[2]),
      );
    } catch (_) {
      return null;
    }
  }

  static void _invalidate(ChatPreviewScope scope) {
    final key = debugKeyFor(scope);
    _generations[key] = (_generations[key] ?? 0) + 1;
  }

  static void _notifyRetirement() {
    _retirementEvents.value++;
  }

  @visibleForTesting
  static void resetForTesting() {
    _generations.clear();
    _profileGenerations.clear();
    _connectionGenerations.clear();
    _sessionGenerations.clear();
    _revisions.clear();
    _completedRevisions.clear();
    _tail = Future<void>.value();
    _tailIdle = true;
  }
}
