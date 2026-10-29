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
/// This deliberately stores a small allowlist rather than an ActiveChat message.
/// It is never consumed by ActiveChat and therefore cannot affect turn state,
/// queueing, retries, completion, or agent context.
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
  static final Map<String, int> _writeVersions = <String, int>{};
  static final Map<String, String?> _latestEncoded = <String, String?>{};
  static final Map<String, int> _inFlightWrites = <String, int>{};
  static final Map<String, ({int scope, int profile, int connection, int session})>
  _latestAdmissions =
      <String, ({int scope, int profile, int connection, int session})>{};

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

  static bool _stillAdmitted(
    ChatPreviewScope scope,
    ({int scope, int profile, int connection, int session}) admission,
  ) {
    final now = _admission(scope);
    return now.scope == admission.scope &&
        now.profile == admission.profile &&
        now.connection == admission.connection &&
        now.session == admission.session;
  }

  static String _identity(Map<String, dynamic> row) {
    final messageId =
        (row['message_id'] ?? row['_desktopMessageId'])?.toString();
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

  static Future<ChatPreviewSnapshot> load(ChatPreviewScope scope) async {
    final admission = _admission(scope);
    try {
      final raw = await _storage.read(key: debugKeyFor(scope));
      if (!_stillAdmitted(scope, admission) || raw == null || raw.isEmpty) {
        return const ChatPreviewSnapshot([]);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['messages'] is! List) {
        return const ChatPreviewSnapshot([]);
      }
      return ChatPreviewSnapshot(_bound(decoded['messages'] as List), admission);
    } catch (_) {
      // Storage availability must not break normal network chat.
      return const ChatPreviewSnapshot([]);
    }
  }

  /// Verifies that a completed device read still belongs to its captured owner.
  static bool isCurrent(ChatPreviewScope scope, ChatPreviewSnapshot snapshot) {
    final admission = snapshot._admission;
    return admission != null && _stillAdmitted(scope, admission);
  }

  static Future<void> save(
    ChatPreviewScope scope,
    Iterable<Map<String, dynamic>> chronologicalRows,
  ) async {
    final key = debugKeyFor(scope);
    final admission = _admission(scope);
    final version = (_writeVersions[key] ?? 0) + 1;
    _writeVersions[key] = version;
    final savedAtMs = DateTime.now().millisecondsSinceEpoch;
    String encode(List<Map<String, dynamic>> messages) => jsonEncode({
      'version': 1,
      'saved_at_ms': savedAtMs,
      'messages': messages,
    });
    final rows = _bound(chronologicalRows).toList(growable: true);
    while (rows.isNotEmpty && utf8.encode(encode(rows)).length > _maxSessionBytes) {
      rows.removeAt(0);
    }
    final encoded = rows.isEmpty ? null : encode(rows);
    _latestEncoded[key] = encoded;
    _latestAdmissions[key] = admission;
    _inFlightWrites[key] = (_inFlightWrites[key] ?? 0) + 1;
    try {
      if (!_stillAdmitted(scope, admission) || _writeVersions[key] != version) {
        return;
      }
      if (encoded == null) {
        await _storage.delete(key: key);
        return;
      }
      await _storage.write(key: key, value: encoded);
      if (!_stillAdmitted(scope, admission) || _writeVersions[key] != version) {
        await _restoreLatest(scope, key);
        return;
      }
      await _evictOldestUntilBound(key);
    } catch (_) {
      // No prompt, identity, endpoint, or storage error is logged here.
    } finally {
      final remaining = (_inFlightWrites[key] ?? 1) - 1;
      if (remaining <= 0) {
        _inFlightWrites.remove(key);
        _latestEncoded.remove(key);
        _latestAdmissions.remove(key);
      } else {
        _inFlightWrites[key] = remaining;
      }
    }
  }

  /// Restores the newest admitted value after a stale platform write finishes.
  /// Re-check after each awaited storage call: a clear or newer publication may
  /// arrive while the platform channel is held.
  static Future<void> _restoreLatest(ChatPreviewScope scope, String key) async {
    final expectedVersion = _writeVersions[key];
    final latest = _latestEncoded[key];
    final latestAdmission = _latestAdmissions[key];
    try {
      if (expectedVersion == null ||
          latest == null ||
          latestAdmission == null ||
          !_stillAdmitted(scope, latestAdmission)) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: latest);
      }
      if (_writeVersions[key] != expectedVersion) {
        await _restoreLatest(scope, key);
      }
    } catch (_) {
      // A later accepted publication can retry; storage failures stay non-fatal.
    }
  }

  static Future<void> _evictOldestUntilBound(String protectedKey) async {
    try {
      final all = await _storage.readAll();
      var bytes = all.entries
          .where((entry) => entry.key.startsWith(_prefix))
          .fold<int>(0, (sum, entry) => sum + utf8.encode(entry.value).length);
      final keys = all.keys.where((key) => key.startsWith(_prefix)).toList()
        ..sort((a, b) {
          int timestamp(String key) {
            try {
              final decoded = jsonDecode(all[key]!);
              return decoded is Map && decoded['saved_at_ms'] is num
                  ? (decoded['saved_at_ms'] as num).toInt()
                  : 0;
            } catch (_) {
              return 0;
            }
          }

          return timestamp(a).compareTo(timestamp(b));
        });
      for (final key in keys) {
        if (bytes <= _maxGlobalBytes) break;
        if (key == protectedKey) continue;
        bytes -= utf8.encode(all[key]!).length;
        await _storage.delete(key: key);
      }
    } catch (_) {}
  }

  static Future<void> clear(ChatPreviewScope scope) async {
    _invalidate(scope);
    try {
      await _storage.delete(key: debugKeyFor(scope));
    } catch (_) {}
  }

  static Future<void> deleteForProfile(String connectionId, String profile) {
    final profileKey = '$connectionId\u0000$profile';
    _profileGenerations[profileKey] = (_profileGenerations[profileKey] ?? 0) + 1;
    return _deleteWhere(
      (scope) =>
          scope.connectionId == connectionId && scope.profile == profile,
    );
  }

  /// Dashboard profile removal has no stable connection id; clear matching
  /// persisted owners across connections after remote success.
  static Future<void> deleteForProfileEverywhere(String profile) =>
      _deleteWhere((scope) => scope.profile == profile);

  static Future<void> deleteForConnection(String connectionId) {
    _connectionGenerations[connectionId] =
        (_connectionGenerations[connectionId] ?? 0) + 1;
    return _deleteWhere((scope) => scope.connectionId == connectionId);
  }

  /// Deletes every local preview that names a remotely deleted durable id.
  /// A caller without a connection binding must fail closed across owners.
  static Future<void> deleteForSession(String sessionId) {
    _sessionGenerations[sessionId] = (_sessionGenerations[sessionId] ?? 0) + 1;
    return _deleteWhere((scope) => scope.sessionId == sessionId);
  }

  static Future<void> _deleteWhere(
    bool Function(ChatPreviewScope scope) matches,
  ) async {
    try {
      final all = await _storage.readAll();
      for (final key in all.keys.where((key) => key.startsWith(_prefix))) {
        final pieces = key.substring(_prefix.length).split('.');
        if (pieces.length != 3) continue;
        String decode(String value) => String.fromCharCodes([
          for (var offset = 0; offset < value.length; offset += 4)
            int.parse(value.substring(offset, offset + 4), radix: 16),
        ]);
        try {
          final scope = ChatPreviewScope(
            connectionId: decode(pieces[0]),
            profile: decode(pieces[1]),
            sessionId: decode(pieces[2]),
          );
          if (!matches(scope)) continue;
          _invalidate(scope);
          await _storage.delete(key: key);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static void _invalidate(ChatPreviewScope scope) {
    final key = debugKeyFor(scope);
    _generations[key] = (_generations[key] ?? 0) + 1;
    _writeVersions[key] = (_writeVersions[key] ?? 0) + 1;
    _latestEncoded.remove(key);
    _latestAdmissions.remove(key);
  }

  @visibleForTesting
  static void resetForTesting() {
    _generations.clear();
    _profileGenerations.clear();
    _connectionGenerations.clear();
    _sessionGenerations.clear();
    _writeVersions.clear();
    _latestEncoded.clear();
    _latestAdmissions.clear();
  }
}
