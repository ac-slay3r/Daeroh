// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';

void main() {
  PreparedTurn turn({bool attachment = false}) => PreparedTurn(
    connectionId: 'synthetic',
    sessionId: 'chat',
    clientTurnId: 'queued',
    createdAtMs: 1000000,
    updatedAtMs: 1000000,
    text: 'queued text',
    fullText: 'queued text',
    model: 'hermes-agent',
    profile: 'default',
    queued: true,
    state: PreparedTurnState.ambiguous,
    retryBoundary: PreparedTurnRetryBoundary.identity(rowId: 10),
    attachments: attachment
        ? const [
            AttachmentDraft(
              type: AttachmentType.document,
              name: 'synthetic.txt',
              mimeType: 'text/plain',
              sizeBytes: 1,
              localPath: '/synthetic/file',
            ),
          ]
        : const [],
  );
  Map<String, dynamic> row(int id, String text, double at) => {
    'id': id,
    'role': 'user',
    'content': text,
    'timestamp': at,
  };
  AmbiguousRetryEvidence evidence(
    double at, {
    bool duplicate = false,
    bool attachment = false,
    bool boundaryPresent = true,
  }) => ambiguousTurnTranscriptEvidence(
    turn(attachment: attachment),
    [
      if (boundaryPresent) row(10, 'before', 800),
      if (duplicate) row(11, 'queued text', 910),
      row(12, 'queued text', at),
      row(13, 'later text', 1010),
    ],
    requireRowAfterTurnCreation: true,
    allowRelaxedQueuedSettlement: true,
  );

  for (final (label, at) in <(String, double)>[
    ('30 seconds', 970),
    ('90 seconds', 910),
    ('just under bound', 880.001),
    ('exact bound', 880),
  ]) {
    test('queued clock ahead $label settles', () {
      expect(evidence(at), AmbiguousRetryEvidence.delivered);
    });
  }
  test('beyond bound stays pending', () {
    expect(evidence(879.999), AmbiguousRetryEvidence.unknown);
  });
  test('additional earlier textual match is ambiguous', () {
    expect(evidence(1001, duplicate: true), AmbiguousRetryEvidence.unknown);
  });
  test('phone behind remains delivered', () {
    expect(evidence(1060), AmbiguousRetryEvidence.delivered);
  });
  test('attachments remain fail closed', () {
    expect(evidence(970, attachment: true), AmbiguousRetryEvidence.unknown);
  });
  test('missing boundary on a history page remains unknown', () {
    expect(
      evidence(970, boundaryPresent: false),
      AmbiguousRetryEvidence.unknown,
    );
  });
  test('identical text before identity boundary does not compete', () {
    expect(
      ambiguousTurnTranscriptEvidence(
        turn(),
        [
          row(9, 'queued text', 910),
          row(10, 'before', 920),
          row(12, 'queued text', 970),
          row(13, 'later', 1010),
        ],
        requireRowAfterTurnCreation: true,
        allowRelaxedQueuedSettlement: true,
      ),
      AmbiguousRetryEvidence.delivered,
    );
  });
}
