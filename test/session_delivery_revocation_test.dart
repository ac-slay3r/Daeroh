// SPDX-FileCopyrightText: 2026 Daeroh contributors
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

class _HeldPersistence implements TurnOutboxPersistence {
  final entered = Completer<void>();
  final release = Completer<void>();
  int saves = 0;
  @override
  Future<void> save(PreparedTurn turn) async {
    saves++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  @override
  Future<void> delete(PreparedTurn turn) async {}
}

void main() {
  setUp(LocalConversationCleanupFence.resetForTesting);

  test(
    'session revocation reaches replaced but still-live services without touching others',
    () {
      final revoked = <String>[];
      final first = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'c',
        profile: 'p',
        sessionId: 'canonical',
      );
      LocalConversationCleanupFence.beginServiceLifecycle(
        first,
        onDeleted: () => revoked.add('old'),
      );

      final replacement = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'c',
        profile: 'p',
        sessionId: 'canonical',
      );
      LocalConversationCleanupFence.beginServiceLifecycle(
        replacement,
        onDeleted: () => revoked.add('new'),
      );
      final other = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'c',
        profile: 'p',
        sessionId: 'unrelated',
      );
      LocalConversationCleanupFence.beginServiceLifecycle(
        other,
        onDeleted: () => revoked.add('unrelated'),
      );
      final aliases = LocalConversationCleanupFence.revokeDeletedSession(
        connectionId: 'c',
        profile: 'p',
        sessionId: 'canonical',
      );
      expect(aliases, {'canonical'});
      expect(revoked, unorderedEquals(['old', 'new']));
      LocalConversationCleanupFence.ensureWriteAllowed(
        connectionId: 'c',
        profile: 'p',
        sessionId: 'unrelated',
        lifecycle: other,
      );
    },
  );

  test(
    'deletion during held pre-transport save cannot grant transport authority',
    () async {
      final persistence = _HeldPersistence();
      final now = DateTime.now().millisecondsSinceEpoch;
      final delivery = ActiveTurnDelivery(
        prepared: PreparedTurn(
          connectionId: 'c',
          profile: 'p',
          sessionId: 'canonical',
          clientTurnId: 'queued',
          createdAtMs: now,
          updatedAtMs: now,
          text: 'synthetic queued turn',
          attachments: const [],
          model: 'model',
          queued: true,
        ),
        store: persistence,
      );
      final route = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'c',
        profile: 'p',
        sessionId: 'canonical',
      );
      LocalConversationCleanupFence.beginServiceLifecycle(
        route,
        onDeleted: delivery.revokeForDeletedSession,
      );
      final beginning = delivery.beginTransport(PreparedTurnTransport.desktop);
      await persistence.entered.future;
      LocalConversationCleanupFence.revokeDeletedSession(
        connectionId: 'c',
        profile: 'p',
        sessionId: 'canonical',
      );
      persistence.release.complete();
      expect(await beginning, isFalse);
      expect(delivery.discarded, isTrue);
      expect(delivery.transportStarted, isFalse);
      // Held or lost acknowledgement callbacks cannot persist another state.
      await delivery.markAccepted();
      await delivery.markRunning();
      await delivery.markUnaccepted();
      expect(persistence.saves, 1);
    },
  );
}
