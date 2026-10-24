import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/skills_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

DashboardClient _dashboard(http.Client client) => DashboardClient(
  host: '127.0.0.1',
  port: 9119,
  manualToken: 'dashboard-test-token',
  httpClientOverride: client,
);

void main() {
  group('Dashboard skill toggle is profile-scoped', () {
    Future<http.Request> toggle(String? profile) async {
      final requests = <http.Request>[];
      final client = _dashboard(
        MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({'ok': true, 'name': 'arxiv', 'enabled': false}),
            200,
          );
        }),
      );
      final result = await client.setSkillEnabled(
        'arxiv',
        false,
        profile: profile,
      );
      expect(result['ok'], isTrue);
      return requests.single;
    }

    test('a named profile is sent in both the query and the body', () async {
      final request = await toggle('android');
      expect(request.method, 'PUT');
      expect(request.url.path, '/api/skills/toggle');
      expect(request.url.queryParameters, {'profile': 'android'});
      expect(jsonDecode(request.body), {
        'name': 'arxiv',
        'enabled': false,
        'profile': 'android',
      });
    });

    test('default and empty profiles stay unscoped', () async {
      for (final profile in [null, '', 'default']) {
        final request = await toggle(profile);
        expect(request.url.path, '/api/skills/toggle');
        expect(request.url.queryParameters, isEmpty, reason: '$profile');
        expect(
          (jsonDecode(request.body) as Map).containsKey('profile'),
          isFalse,
          reason: '$profile',
        );
      }
    });
  });

  group(
    'skill toggle routing never leaks a named profile to global config',
    () {
      test('named profile uses the scoped Dashboard route', () {
        expect(
          skillToggleRoute(
            profile: 'android',
            profileResolved: true,
            dashboardListed: true,
            bridgeSkills: true,
          ),
          SkillToggleRoute.dashboard,
        );
      });

      test('named profile without the Dashboard is blocked, never bridged', () {
        expect(
          skillToggleRoute(
            profile: 'android',
            profileResolved: true,
            dashboardListed: false,
            bridgeSkills: true,
          ),
          SkillToggleRoute.blocked,
        );
      });

      test('an unresolved profile is blocked even with every client ready', () {
        expect(
          skillToggleRoute(
            profile: '',
            profileResolved: false,
            dashboardListed: true,
            bridgeSkills: true,
          ),
          SkillToggleRoute.blocked,
        );
      });

      test('default profile prefers the Dashboard and keeps the bridge', () {
        for (final profile in ['', 'default']) {
          expect(
            skillToggleRoute(
              profile: profile,
              profileResolved: true,
              dashboardListed: true,
              bridgeSkills: true,
            ),
            SkillToggleRoute.dashboard,
          );
          expect(
            skillToggleRoute(
              profile: profile,
              profileResolved: true,
              dashboardListed: false,
              bridgeSkills: true,
            ),
            SkillToggleRoute.bridge,
          );
          expect(
            skillToggleRoute(
              profile: profile,
              profileResolved: true,
              dashboardListed: false,
              bridgeSkills: false,
            ),
            SkillToggleRoute.blocked,
          );
        }
      });
    },
  );

  group('diagnostics skills toggle reflects the Dashboard', () {
    CapabilityMatrix matrix(List<ProbeResult> dash) =>
        ConnectionDiagnostics().buildMatrix(const [], dash, null);

    test('a signed-in Dashboard skills list means toggling is available', () {
      final m = matrix(const [
        ProbeResult(name: 'status', status: ProbeStatus.ok),
        ProbeResult(name: 'auth', status: ProbeStatus.ok),
        ProbeResult(name: 'skills', status: ProbeStatus.ok),
      ]);
      expect(m.skillsToggle, CapState.yes);
    });

    test('without Dashboard sign-in it stays unknown', () {
      final m = matrix(const [
        ProbeResult(name: 'status', status: ProbeStatus.ok),
        ProbeResult(name: 'auth', status: ProbeStatus.authInvalid),
      ]);
      expect(m.skillsToggle, CapState.unknown);
    });
  });
}
