import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/mission_control_copy.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  for (final locale in const [Locale('en'), Locale('es')]) {
    testWidgets(
      '${locale.languageCode} hosted editor and count copy comes from Strings',
      (tester) async {
        late MissionControlCopy copy;
        late Strings strings;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: Builder(
              builder: (context) {
                copy = MissionControlCopy.of(context);
                strings = Strings.of(context);
                return const SizedBox();
              },
            ),
          ),
        );

        expect(copy.save, strings.missionHostedSave);
        expect(copy.cancel, strings.missionHostedCancel);
        expect(copy.roomMemberCount(1), strings.missionHostedMemberCount(1));
        expect(copy.roomMemberCount(2), strings.missionHostedMemberCount(2));
        expect(copy.roomCount(1), strings.missionHostedRoomCount(1));
        expect(copy.roomCount(2), strings.missionHostedRoomCount(2));
        expect(copy.allAgents, strings.missionCopyAllAgents);
        expect(
          copy.roomDriverUnavailable,
          strings.missionCopyRoomDriverUnavailable,
        );
        expect(copy.status('blocked'), strings.missionCopyStatusBlocked);
        expect(
          copy.workspaceAgentCount(1),
          strings.missionCopyWorkspaceAgentCount(1),
        );
        expect(
          copy.workspaceAgentCount(2),
          strings.missionCopyWorkspaceAgentCount(2),
        );
        expect(
          copy.roomHomeSummary(1, 2),
          strings.missionCopyRoomHomeSummary(1, 2),
        );
        expect(
          copy.roomHomeSummary(2, 1),
          strings.missionCopyRoomHomeSummary(2, 1),
        );
        expect(
          copy.unattributedSessions(1),
          strings.missionCopyUnattributedSessions(1),
        );
        expect(
          copy.unattributedSessions(2),
          strings.missionCopyUnattributedSessions(2),
        );
        expect(
          copy.agentCreated('infra'),
          strings.missionCopyAgentCreated('infra'),
        );
        expect(
          copy.workspaceAgentCount(2),
          locale.languageCode == 'en' ? '2 agents' : '2 agentes',
        );
        expect(
          copy.unattributedSessions(1),
          locale.languageCode == 'en'
              ? '1 session did not publish a profile owner. They are included only in overall usage.'
              : '1 sesión no publicó su profile propietario. Solo se incluyen en el uso global.',
        );
      },
    );
  }
}
