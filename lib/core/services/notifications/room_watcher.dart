// T607 — room watcher for the background listener (spec 070 § Room
// notifications). Reads hosted rooms incrementally (`groups.state` +
// `groups.log since_seq`) and turns server evidence into notification
// decisions. The decider is pure; the driver owns IO, backoff and cursors.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../bots/data/bot_mode_repository.dart';
import '../../bots/ui/room/room_prefs.dart';
import '../../models/hosted_groups.dart';
import '../../models/room_member_status.dart' show roomMessageNeedsYou;

/// What the watcher decided for one room tick.
sealed class RoomNotice {
  const RoomNotice();

  /// Durable identity for the event ledger (null = not deduplicated, e.g. the
  /// in-place Live Update refresh).
  String? get dedupeKey;
}

final class RoomApprovalNotice extends RoomNotice {
  final RoomApprovalAction action;
  const RoomApprovalNotice(this.action);
  @override
  String get dedupeKey => 'approval:${action.requestId}';
}

final class RoomMentionNotice extends RoomNotice {
  final HostedGroupEvent event;
  const RoomMentionNotice(this.event);
  @override
  String get dedupeKey => 'mention:${event.eventId}';
}

/// One member reply shown as its own line of the round-finished card.
@immutable
final class RoomRoundReply {
  final String memberId;
  final String text;
  final int timeMs;
  final String eventId;
  const RoomRoundReply({
    required this.memberId,
    required this.text,
    required this.timeMs,
    required this.eventId,
  });
}

final class RoomRoundFinishedNotice extends RoomNotice {
  final List<String> repliedMemberIds;
  final int throughSeq;
  final String? lastText;
  final String? lastMemberId;

  /// Discussion this round belongs to (`discussion_event_id`); the durable
  /// identity of the round, so a round is announced once whether its end
  /// was observed as a driver transition or read from the log.
  final String? discussionId;

  /// Member replies read in this pass (oldest first).
  final List<RoomRoundReply> replies;

  /// Replies before this pass live in the log from here (exclusive); the
  /// driver reads them back so the card lists every member line.
  final int? backfillFromSeq;
  final int? backfillToSeq;

  const RoomRoundFinishedNotice(
    this.repliedMemberIds,
    this.throughSeq, {
    this.lastText,
    this.lastMemberId,
    this.discussionId,
    this.replies = const [],
    this.backfillFromSeq,
    this.backfillToSeq,
  });

  RoomRoundFinishedNotice withReplies(List<RoomRoundReply> all) =>
      RoomRoundFinishedNotice(
        repliedMemberIds,
        throughSeq,
        lastText: lastText,
        lastMemberId: lastMemberId,
        discussionId: discussionId,
        replies: List.unmodifiable(all),
      );

  @override
  String get dedupeKey =>
      discussionId != null ? 'round:d:$discussionId' : 'round:$throughSeq';
}

final class RoomMemberFailedNotice extends RoomNotice {
  final HostedGroupEvent event;
  const RoomMemberFailedNotice(this.event);
  @override
  String get dedupeKey => 'failed:${event.eventId}';
}

final class RoomBlockedNotice extends RoomNotice {
  final int atSeq;
  const RoomBlockedNotice(this.atSeq);
  @override
  String get dedupeKey => 'blocked:$atSeq';
}

/// Live Update refresh (or end) while the room works.
final class RoomLiveNotice extends RoomNotice {
  final bool working;
  final List<({String memberId, String state})> members;
  final String? workingMemberId;
  final int? round;
  final int? startedAtMs;

  /// Member handles @-addressed in the current round (user message and
  /// member hand-offs, oldest first, lower-case). Lets the Live Update name
  /// the Bot that is about to answer before its turn is in the log.
  final List<String> addressedHandles;

  /// Member id → time from the round's user message to that member's
  /// reply (server clock), for the expanded "Replied · 00:41" rows.
  final Map<String, int> repliedAfterMs;
  const RoomLiveNotice({
    required this.working,
    this.members = const [],
    this.workingMemberId,
    this.round,
    this.startedAtMs,
    this.addressedHandles = const [],
    this.repliedAfterMs = const {},
  });
  @override
  String? get dedupeKey => null;
}

/// Approvals that disappeared from `pending_actions` (answered anywhere).
final class RoomApprovalClearedNotice extends RoomNotice {
  final String requestId;
  const RoomApprovalClearedNotice(this.requestId);
  @override
  String? get dedupeKey => null;
}

/// Persisted per-room watcher state (no message text).
@immutable
class RoomWatchState {
  final int cursor;
  final bool working;
  final bool blocked;
  final List<String> repliers;
  final String? lastMemberId;
  final Set<String> pendingRequestIds;
  final int? workingSinceMs;
  final int? round;

  /// Members with a `turn.started` not yet settled (server evidence only).
  final Set<String> openMembers;

  /// Current round's discussion (`discussion_event_id`), when known.
  final String? discussion;

  /// Sequence just before the `message.user` that opened the current round.
  final int? roundFromSeq;

  /// A user message opened a round that has not settled yet (epoch ms of
  /// the message). Keeps the fast cadence and the Live Update even before
  /// the driver reports `working`.
  final int? roundOpenSinceMs;

  /// Last discussion announced as finished (local dedupe; the ledger is
  /// the cross-process authority).
  final String? finishedDiscussion;

  /// Handles @-addressed in the current round (no message text).
  final List<String> addressed;

  /// Server time (epoch ms) of the user message that opened the round.
  final int? roundUserAtMs;

  /// Member id → ms from [roundUserAtMs] to its first reply this round.
  final Map<String, int> repliedAfterMs;

  const RoomWatchState({
    this.addressed = const [],
    this.roundUserAtMs,
    this.repliedAfterMs = const {},
    this.openMembers = const {},
    this.discussion,
    this.roundFromSeq,
    this.roundOpenSinceMs,
    this.finishedDiscussion,
    this.cursor = 0,
    this.working = false,
    this.blocked = false,
    this.repliers = const [],
    this.lastMemberId,
    this.pendingRequestIds = const {},
    this.workingSinceMs,
    this.round,
  });

  Map<String, Object?> toJson() => {
    'cursor': cursor,
    'working': working,
    'blocked': blocked,
    'repliers': repliers,
    'last': ?lastMemberId,
    'pending': pendingRequestIds.toList(),
    'since': ?workingSinceMs,
    'round': ?round,
    'open': openMembers.toList(),
    'disc': ?discussion,
    'from': ?roundFromSeq,
    'opened': ?roundOpenSinceMs,
    'done': ?finishedDiscussion,
    if (addressed.isNotEmpty) 'addr': addressed,
    'uat': ?roundUserAtMs,
    if (repliedAfterMs.isNotEmpty) 'rms': repliedAfterMs,
  };

  /// Whether a round is in flight by any evidence (driver or log).
  bool get live => working || roundOpenSinceMs != null;

  static RoomWatchState fromJson(Object? raw) {
    if (raw is! Map) return const RoomWatchState();
    List<String> strings(Object? v) => [
      if (v is List)
        for (final e in v)
          if (e is String) e,
    ];
    return RoomWatchState(
      cursor: raw['cursor'] is int ? raw['cursor'] as int : 0,
      working: raw['working'] == true,
      blocked: raw['blocked'] == true,
      repliers: strings(raw['repliers']),
      lastMemberId: raw['last'] as String?,
      pendingRequestIds: strings(raw['pending']).toSet(),
      workingSinceMs: raw['since'] is int ? raw['since'] as int : null,
      round: raw['round'] is int ? raw['round'] as int : null,
      openMembers: strings(raw['open']).toSet(),
      discussion: raw['disc'] is String ? raw['disc'] as String : null,
      roundFromSeq: raw['from'] is int ? raw['from'] as int : null,
      roundOpenSinceMs: raw['opened'] is int ? raw['opened'] as int : null,
      finishedDiscussion: raw['done'] is String ? raw['done'] as String : null,
      addressed: strings(raw['addr']).take(maxAddressedHandles).toList(),
      roundUserAtMs: raw['uat'] is int ? raw['uat'] as int : null,
      repliedAfterMs: {
        if (raw['rms'] is Map)
          for (final e in (raw['rms'] as Map).entries.take(12))
            if (e.key is String && e.value is int && (e.value as int) >= 0)
              e.key as String: e.value as int,
      },
    );
  }
}

/// Cap on the @-handles remembered per round.
const maxAddressedHandles = 8;

final _handlePattern = RegExp(
  r'(?:^|[^\w@])@([a-z0-9][a-z0-9_-]{0,63})',
  caseSensitive: false,
);

/// Lower-case @handles in [text], in order, without `@user`.
List<String> addressedHandlesIn(String? text) {
  if (text == null || text.isEmpty) return const [];
  final out = <String>[];
  for (final m in _handlePattern.allMatches(text)) {
    final h = m.group(1)!.toLowerCase();
    if (h == 'user' || h == 'all' || out.contains(h)) continue;
    out.add(h);
  }
  return out;
}

/// A round opened by a user message that never settles stops holding the
/// fast cadence / Live Update after this long.
const roomRoundOpenTimeout = Duration(minutes: 15);

/// Pure decision step. [previous] is null on first sight of the room: then
/// only currently pending approvals surface (history is never replayed).
///
/// A round's end is derived from the LOG (`room.activity` settled|bounded,
/// or member replies followed by an idle driver with no open turn) as well
/// as from an observed working → idle transition, so a round that starts
/// and finishes between two listener ticks is still announced, once per
/// discussion.
({List<RoomNotice> notices, RoomWatchState next}) decideRoomNotices({
  required RoomWatchState? previous,
  required RoomDriverStatus? driverStatus,
  required List<HostedGroupEvent> newEvents,
  required int latestSeq,
  required RoomNotificationLevel level,
  required int nowMs,
}) {
  final notices = <RoomNotice>[];
  final status = driverStatus ?? RoomDriverStatus.unknown;
  final approvals = status.approvals.toList();
  final pendingIds = {for (final a in approvals) a.requestId};
  final before = previous ?? const RoomWatchState();

  // Approvals surface in every level, muted included.
  for (final action in approvals) {
    if (!before.pendingRequestIds.contains(action.requestId) ||
        previous == null) {
      notices.add(RoomApprovalNotice(action));
    }
  }
  for (final gone in before.pendingRequestIds.difference(pendingIds)) {
    notices.add(RoomApprovalClearedNotice(gone));
  }

  if (previous == null) {
    return (
      notices: notices,
      next: RoomWatchState(
        cursor: latestSeq,
        working: status.working,
        blocked: status.blocked,
        pendingRequestIds: pendingIds,
        workingSinceMs: status.working ? nowMs : null,
      ),
    );
  }

  final windowFrom = before.cursor;
  var repliers = [...before.repliers];
  var lastMember = before.lastMemberId;
  String? lastText;
  var round = before.round;
  var discussion = before.discussion;
  var roundFrom = before.roundFromSeq;
  var openedAt = before.roundOpenSinceMs;
  var finishedDiscussion = before.finishedDiscussion;
  var replies = <RoomRoundReply>[];
  var addressed = [...before.addressed];
  var userAt = before.roundUserAtMs;
  final replyAfter = <String, int>{...before.repliedAfterMs};
  void address(String? text) {
    for (final h in addressedHandlesIn(text)) {
      if (addressed.length >= maxAddressedHandles) break;
      if (!addressed.contains(h)) addressed.add(h);
    }
  }

  var finishedAny = false;
  final open = <String>{...before.openMembers};
  final startedNow = <String>[];

  void finishRound(int throughSeq) {
    final key = discussion;
    final already = key != null && key == finishedDiscussion;
    if (!already && level == RoomNotificationLevel.all && repliers.isNotEmpty) {
      // Replies older than this pass are read back from the log.
      final backfill = roundFrom != null && roundFrom! < windowFrom
          ? roundFrom
          : null;
      notices.add(
        RoomRoundFinishedNotice(
          List.unmodifiable(repliers),
          throughSeq,
          lastText: lastText,
          lastMemberId: lastMember,
          discussionId: key,
          replies: List.unmodifiable(replies),
          backfillFromSeq: backfill,
          backfillToSeq: backfill == null ? null : windowFrom,
        ),
      );
    }
    if (key != null) finishedDiscussion = key;
    finishedAny = true;
    repliers = [];
    replies = [];
    lastText = null;
    round = null;
    roundFrom = null;
    openedAt = null;
    addressed = [];
    userAt = null;
    replyAfter.clear();
    open.clear();
  }

  for (final event in newEvents) {
    final member = event.activity.memberId ?? event.actor.id;
    final eventDiscussion = event.activity.discussionId;
    switch (event.kind) {
      case 'message.user':
        repliers = [];
        replies = [];
        lastMember = null;
        lastText = null;
        round = null;
        discussion = null;
        roundFrom = event.sequence - 1;
        // Phone clock (the Live Update chronometer runs on it).
        openedAt = nowMs;
        addressed = [];
        userAt = (event.createdAt * 1000).round();
        replyAfter.clear();
        address(event.publicText);
      case 'message.member':
        if (eventDiscussion != null) discussion = eventDiscussion;
        // First sight of a round after its user message (cursor adopted
        // mid-round): the round starts no later than this reply, so earlier
        // replies read in other passes are still backfilled from the log.
        roundFrom ??= event.sequence - 1;
        if (!repliers.contains(member)) repliers.add(member);
        final at = userAt;
        if (at != null && !replyAfter.containsKey(member)) {
          final after = (event.createdAt * 1000).round() - at;
          if (after >= 0) replyAfter[member] = after;
        }
        lastMember = member;
        lastText = event.publicText;
        address(event.publicText);
        final text = event.publicText;
        if (text != null && text.trim().isNotEmpty) {
          replies.add(
            RoomRoundReply(
              memberId: member,
              text: text,
              timeMs: (event.createdAt * 1000).round(),
              eventId: event.eventId,
            ),
          );
        }
        if (level != RoomNotificationLevel.muted &&
            roomMessageNeedsYou(event.publicText ?? '')) {
          notices.add(RoomMentionNotice(event));
        }
      case 'turn.started':
        if (eventDiscussion != null) discussion = eventDiscussion;
        open.add(member);
        startedNow.add(member);
        final r = event.activity.roundIndex;
        if (r != null) round = r + 1;
      case 'turn.failed':
        if (eventDiscussion != null) discussion ??= eventDiscussion;
        open.remove(member);
        if (level != RoomNotificationLevel.muted) {
          notices.add(RoomMemberFailedNotice(event));
        }
      case 'turn.settled' ||
          'turn.cancelled' ||
          'turn.deferred' ||
          'turn.reassigned':
        if (eventDiscussion != null) discussion ??= eventDiscussion;
        open.remove(member);
      case 'room.activity':
        final st = event.activity.status;
        if (st == 'settled' || st == 'bounded') {
          if (eventDiscussion != null) discussion ??= eventDiscussion;
          finishRound(event.sequence);
        }
    }
  }

  if (status.blocked &&
      !before.blocked &&
      level != RoomNotificationLevel.muted) {
    notices.add(RoomBlockedNotice(latestSeq));
  }

  // Round end without a gateway verdict in the log (older gateways, or the
  // verdict not written yet): an observed working → idle transition after
  // replies ends it at once (the original rule). A round that was never
  // seen working may be idle for a moment between two members' turns, so
  // it only ends after a second consecutive idle pass with nothing new.
  final idle = !status.working && open.isEmpty && !status.blocked;
  final observedEnd = before.working && !status.working;
  final quietIdle =
      idle && !before.working && newEvents.isEmpty && repliers.isNotEmpty;
  if (quietIdle && roundFrom == null && discussion == null) {
    // Leftovers of the pre-log-derived state (a missed round): drop them
    // silently rather than announce a stale round after an update.
    repliers = [];
    round = null;
  } else if (repliers.isNotEmpty && (observedEnd || quietIdle)) {
    finishRound(latestSeq);
  } else if (observedEnd) {
    // The driver finished a round in which nobody replied.
    finishRound(latestSeq);
  }
  if (openedAt != null &&
      nowMs - openedAt! > roomRoundOpenTimeout.inMilliseconds) {
    openedAt = null;
  }

  final liveNow = status.working || openedAt != null;
  final since = liveNow
      ? (before.live
            ? before.workingSinceMs ?? openedAt ?? nowMs
            : openedAt ?? nowMs)
      : null;
  if (level == RoomNotificationLevel.all && (liveNow || before.live)) {
    notices.add(
      RoomLiveNotice(
        working: liveNow,
        workingMemberId: liveNow
            ? (startedNow.isNotEmpty
                  ? startedNow.last
                  : open.isNotEmpty
                  ? open.last
                  : null)
            : null,
        members: [
          for (final id in repliers) (memberId: id, state: 'done'),
          for (final id in open)
            if (!repliers.contains(id)) (memberId: id, state: 'working'),
          for (final a in approvals) (memberId: a.memberId, state: 'needs_you'),
        ],
        round: round,
        startedAtMs: since,
        addressedHandles: List.unmodifiable(addressed),
        repliedAfterMs: Map.unmodifiable(replyAfter),
      ),
    );
  }

  final settled = finishedAny && openedAt == null && !status.working;
  return (
    notices: notices,
    next: RoomWatchState(
      cursor: latestSeq,
      working: status.working,
      blocked: status.blocked,
      repliers: repliers,
      lastMemberId: lastMember,
      pendingRequestIds: pendingIds,
      workingSinceMs: since,
      round: round,
      openMembers: status.running || status.working ? open : const {},
      discussion: settled ? null : discussion,
      addressed: liveNow ? addressed : const [],
      roundUserAtMs: liveNow ? userAt : null,
      repliedAfterMs: liveNow ? Map.unmodifiable(replyAfter) : const {},
      roundFromSeq: roundFrom,
      roundOpenSinceMs: openedAt,
      finishedDiscussion: finishedDiscussion,
    ),
  );
}

/// Last observed room for widgets and presence.
@immutable
class RoomWatchView {
  final HostedGroupRoom room;
  final RoomDriverStatus? driverStatus;
  final RoomWatchState state;
  final String? lastMemberId;
  final String? lastText;

  const RoomWatchView({
    required this.room,
    required this.driverStatus,
    required this.state,
    this.lastMemberId,
    this.lastText,
  });
}

/// Presents decisions (implemented by the listener with rich notifications).
abstract interface class RoomNoticePresenter {
  /// A plain exception means no deduped notice was delivered. A presenter
  /// that can partially deliver must throw [RoomNoticePresentationFailure]
  /// with the keys already accepted by its sink. Normal return commits all.
  Future<void> present(
    String connId,
    HostedGroupRoom room,
    List<RoomNotice> notices,
  );
}

/// A batch can post approvals before a later notice fails. Only identities
/// acknowledged by the presenter remain claimed when that batch is retried.
class RoomNoticePresentationFailure implements Exception {
  RoomNoticePresentationFailure(this.cause, Iterable<String> deliveredKeys)
    : deliveredKeys = Set.unmodifiable(deliveredKeys);

  final Object cause;
  final Set<String> deliveredKeys;
}

/// Claims a dedupe key once across isolates (the notification ledger).
typedef RoomNoticeClaim =
    Future<bool> Function(String connId, String roomId, String dedupeKey);

typedef RoomNoticeRelease =
    Future<void> Function(String connId, String roomId, String dedupeKey);

/// IO driver for one connection. Called from the listener tick; holds no
/// timers. Backoff is per connection and doubles up to [maxDelay].
class RoomWatcher {
  RoomWatcher({
    required this.connId,
    required this.prefs,
    required this.presenter,
    required this.claim,
    required this.release,
    DateTime Function()? now,
    this.baseDelay = const Duration(minutes: 1),
    this.maxDelay = const Duration(minutes: 15),
    this.maxRooms = 12,
    this.pageLimit = 100,
    this.maxPagesPerTick = 8,
  }) : _now = now ?? DateTime.now;

  final String connId;
  final SharedPreferences prefs;
  final RoomNoticePresenter presenter;
  final RoomNoticeClaim claim;
  final RoomNoticeRelease release;
  final Duration baseDelay;
  final Duration maxDelay;

  /// Maximum room reads per pass, not a cap on retained room state.
  /// A non-positive budget performs listing/pruning only.
  final int maxRooms;
  final int pageLimit;

  /// Log pages read per room per tick. A longer backlog resumes from the
  /// server cursor on the next tick; events are never skipped.
  final int maxPagesPerTick;
  final DateTime Function() _now;

  int _failures = 0;
  DateTime? _retryAt;
  bool _anyWorking = false;
  int _nextRoomIndex = 0;
  final Map<String, int> _roomOrder = {};
  Set<String> _listedRoomIds = const {};
  final Map<String, ({String memberId, String text})> _lastMessages = {};
  List<RoomWatchView> _views = const [];

  /// Last successful evidence for each still-listed room, including rooms
  /// skipped by the polling budget or whose latest read failed. Unknown is
  /// not completion. This cache lives only for this connection's watcher;
  /// it is replaced on successful reads and pruned by the full listing.
  List<RoomWatchView> get views => _views;

  /// All active rooms in the last successful listing, including rooms not
  /// polled this pass. Used to keep their Live Updates until removal.
  Set<String> get listedRoomIds => _listedRoomIds;

  static const storageKey = 'bg_room_watch_v1';

  // Failed releases survive watcher recreation. Store only authoritative
  // identities, never notice text, and drain before claiming this room again.
  String _releaseKey(String roomId) =>
      'bg_room_release_v1:${jsonEncode([connId, roomId])}';

  // Keep the obligation even if journal creation fails. A missing durable
  // journal must not let this watcher reclaim or advance an undelivered room.
  final Map<String, Set<String>> _pendingReleases = {};

  Future<void> _drainReleases(String roomId) async {
    final key = _releaseKey(roomId);
    // A failed remove can still evict the local preferences cache. Consult
    // durable storage before deciding recovery is complete (also on restart).
    await prefs.reload();
    final pending = <String>{
      ...?_pendingReleases[roomId],
      ...?prefs.getStringList(key),
    };
    if (pending.isEmpty) return;
    _pendingReleases[roomId] = pending;
    // Best effort crash recovery. Failure (including a false return) does not
    // discard memory or prevent release through the independently stored ledger.
    // Retry journaling on every drain if release remains unavailable.
    try {
      await prefs.setStringList(key, pending.toList());
    } catch (_) {
      // The in-memory obligation remains until release AND removal succeed.
    }
    for (final dedupe in pending) {
      await release(connId, roomId, dedupe);
    }
    if (!await prefs.remove(key)) {
      throw StateError('Could not persist room claim release');
    }
    _pendingReleases.remove(roomId);
  }

  Future<void> _releaseFailed(String roomId, Set<String> keys) async {
    if (keys.isEmpty) return;
    (_pendingReleases[roomId] ??= <String>{}).addAll(keys);
    await _drainReleases(roomId);
  }

  bool get anyWorking => _anyWorking;
  Duration? get retryAfter {
    final at = _retryAt;
    if (at == null) return null;
    final left = at.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get allowsAttempt => _retryAt == null || !_now().isBefore(_retryAt!);

  void _recordFailure() {
    _failures++;
    var delay = baseDelay;
    for (var i = 1; i < _failures && delay < maxDelay; i++) {
      delay *= 2;
    }
    if (delay > maxDelay) delay = maxDelay;
    _retryAt = _now().add(delay);
  }

  Map<String, Object?> _loadAll() {
    try {
      final raw = prefs.getString(storageKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      return decoded is Map ? Map<String, Object?>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  static String roomKey(String connId, HostedGroupRoom room) =>
      '$connId|${room.authorityGatewayId}:${room.roomId}';

  /// Same key the Room screen writes (`SharedPreferencesRoomPrefs`).
  static String prefsRoomKey(HostedGroupRoom room) =>
      '${room.authorityGatewayId}:${room.roomId}';

  /// Replies of a round that began before this pass are read back from the
  /// log (bounded) so the card lists every member line. Best effort: the
  /// summary still posts when the read fails.
  Future<RoomRoundFinishedNotice> _withEarlierReplies(
    BotModeGateway gateway,
    HostedGroupRoom room,
    RoomRoundFinishedNotice notice,
    GroupsCapabilities caps,
  ) async {
    final from = notice.backfillFromSeq;
    final to = notice.backfillToSeq;
    if (from == null || to == null || to <= from) return notice;
    try {
      final earlier = <RoomRoundReply>[];
      var since = from;
      for (var page = 0; page < 2 && since < to; page++) {
        final log = await gateway.groupLog(
          room.roomId,
          sinceSeq: since,
          limit: pageLimit,
          generation: caps.generation,
        );
        for (final e in log.events) {
          if (e.sequence > to) break;
          final text = e.publicText;
          if (e.kind == 'message.member' &&
              text != null &&
              text.trim().isNotEmpty &&
              (notice.discussionId == null ||
                  e.activity.discussionId == null ||
                  e.activity.discussionId == notice.discussionId)) {
            earlier.add(
              RoomRoundReply(
                memberId: e.activity.memberId ?? e.actor.id,
                text: text,
                timeMs: (e.createdAt * 1000).round(),
                eventId: e.eventId,
              ),
            );
          }
        }
        if (log.cursor <= since || !log.hasMore) break;
        since = log.cursor;
      }
      final seen = {for (final r in notice.replies) r.eventId};
      return notice.withReplies([
        for (final r in earlier)
          if (!seen.contains(r.eventId)) r,
        ...notice.replies,
      ]);
    } catch (_) {
      return notice;
    }
  }

  /// One incremental pass. True means the listing and at least one room read
  /// succeeded (or no reads were scheduled); views retain still-listed evidence.
  Future<bool> tick(BotModeGateway gateway) async {
    if (!allowsAttempt) return false;
    final all = _loadAll();
    final roomPrefs = SharedPreferencesRoomPrefs(prefs);
    var working = false;
    try {
      final caps = await gateway.groupCapabilities();
      if (!caps.methods.contains(GroupMethod.state) ||
          !caps.methods.contains(GroupMethod.log)) {
        _failures = 0;
        _retryAt = _now().add(maxDelay);
        return false;
      }
      final listedRooms = (await gateway.listGroups(
        generation: caps.generation,
      )).where((r) => !r.disbanded).toList();
      final listedKeys = {
        for (final room in listedRooms) roomKey(connId, room),
      };
      // Keep first-seen order for retained identities; append new rooms in
      // listing order. Reindex after removals to bound the in-memory metadata.
      final orderedKeys = [
        ..._roomOrder.keys.where(listedKeys.contains),
        ...listedKeys.where((key) => !_roomOrder.containsKey(key)),
      ];
      _roomOrder
        ..clear()
        ..addEntries([
          for (var i = 0; i < orderedKeys.length; i++)
            MapEntry(orderedKeys[i], i),
        ]);
      listedRooms.sort(
        (a, b) => _roomOrder[roomKey(connId, a)]!.compareTo(
          _roomOrder[roomKey(connId, b)]!,
        ),
      );
      // Rotate attempted slices even when individual rooms fail, so one bad
      // room cannot starve the tail. Failed room state remains untouched.
      // Stable identity order prevents server-side activity reordering from
      // repeatedly moving a room out of the next slice. For stable membership
      // and a positive budget, every room is attempted within ceil(count /
      // maxRooms) passes. The in-memory offset resets on watcher recreation;
      // membership changes wrap it into the new list without pruning skips.
      final count = listedRooms.length;
      final start = count == 0 ? 0 : _nextRoomIndex % count;
      var take = maxRooms;
      if (take < 0) take = 0;
      if (take > count) take = count;
      final rooms = [
        for (var i = 0; i < take; i++) listedRooms[(start + i) % count],
      ];
      final views = <RoomWatchView>[];
      for (final listed in rooms) {
        try {
          await _drainReleases(listed.roomId);
          final key = roomKey(connId, listed);
          final previousRaw = all[key];
          final previous = previousRaw == null
              ? null
              : RoomWatchState.fromJson(previousRaw);
          // Quiet rooms cost one `groups.state`; the log is read only when
          // the server says there is something past our cursor.
          final state = await gateway.groupState(
            listed.roomId,
            generation: caps.generation,
          );
          final room = state.room;
          var events = <HostedGroupEvent>[];
          var latest = room.latestSeq;
          if (previous != null && room.latestSeq > previous.cursor) {
            var since = previous.cursor;
            for (var page = 0; page < maxPagesPerTick; page++) {
              final log = await gateway.groupLog(
                room.roomId,
                sinceSeq: since,
                limit: pageLimit,
                generation: caps.generation,
              );
              events.addAll(log.events);
              final stalled = log.cursor <= since;
              since = log.cursor;
              // Complete read: adopt the head. Partial: the next tick resumes
              // from the cursor we actually reached.
              latest = log.hasMore && !stalled ? log.cursor : log.latestSeq;
              if (!log.hasMore || stalled) break;
            }
          } else if (previous != null && room.latestSeq < previous.cursor) {
            // Authority rotated or the log rewound: rebaseline silently.
            events = [];
          }
          final level = await roomPrefs.notificationLevel(prefsRoomKey(room));
          final decision = decideRoomNotices(
            previous: previous,
            driverStatus: state.driverStatus,
            newEvents: events,
            latestSeq: latest,
            level: level,
            nowMs: _now().millisecondsSinceEpoch,
          );
          working = working || decision.next.live;
          final fresh = <RoomNotice>[];
          final acquired = <String>{};
          try {
            for (final notice in decision.notices) {
              final dedupe = notice.dedupeKey;
              if (dedupe != null) {
                if (!await claim(connId, room.roomId, dedupe)) continue;
                acquired.add(dedupe);
              }
              fresh.add(
                notice is RoomRoundFinishedNotice
                    ? await _withEarlierReplies(gateway, room, notice, caps)
                    : notice,
              );
            }
            if (fresh.isNotEmpty) {
              await presenter.present(connId, room, fresh);
            }
          } catch (error) {
            if (error is RoomNoticePresentationFailure) {
              acquired.removeAll(error.deliveredKeys);
            }
            await _releaseFailed(room.roomId, acquired);
            rethrow;
          }
          all[key] = decision.next.toJson();
          for (final event in events) {
            if (event.kind == 'message.member' && event.publicText != null) {
              _lastMessages[key] = (
                memberId: event.activity.memberId ?? event.actor.id,
                text: event.publicText!,
              );
            }
          }
          views.add(
            RoomWatchView(
              room: room,
              driverStatus: state.driverStatus,
              state: decision.next,
              lastMemberId: _lastMessages[key]?.memberId,
              lastText: _lastMessages[key]?.text,
            ),
          );
        } catch (error) {
          if (kDebugMode) {
            debugPrint(
              '[hermes-rooms] room read failed (${error.runtimeType})',
            );
          }
        }
      }
      final retained = <String, RoomWatchView>{
        for (final view in _views)
          if (listedKeys.contains(roomKey(connId, view.room)))
            roomKey(connId, view.room): view,
        for (final view in views) roomKey(connId, view.room): view,
      };
      _views = List.unmodifiable(retained.values);
      // Only an absent/disbanded room is removed. Skipping a room in the
      // current slice must not discard its cursor or pending approval state.
      all.removeWhere(
        (key, _) => key.startsWith('$connId|') && !listedKeys.contains(key),
      );
      await prefs.setString(storageKey, jsonEncode(all));
      _nextRoomIndex = count == 0 ? 0 : (start + take) % count;
      _listedRoomIds = Set.unmodifiable({
        for (final room in listedRooms) room.roomId,
      });
      _anyWorking =
          working ||
          listedKeys.any(
            (key) => all[key] != null && RoomWatchState.fromJson(all[key]).live,
          );
      if (rooms.isNotEmpty && views.isEmpty) {
        _recordFailure();
        return false;
      }
      _failures = 0;
      _retryAt = null;
      return true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[hermes-rooms] watch failed (${error.runtimeType})');
      }
      _recordFailure();
      return false;
    }
  }
}
