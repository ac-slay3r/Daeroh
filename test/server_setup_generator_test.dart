import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/core/services/server_setup_generator.dart';

void main() {
  test('pairing command is a verified download, not pipe-to-shell', () {
    expect(ServerSetupGenerator.curlCommand, contains('sha256sum -c -'));
    expect(ServerSetupGenerator.curlCommand, contains('sh "\$file"'));
    expect(ServerSetupGenerator.curlCommand, isNot(contains('| sh "')));
  });

  test('setup script is Linux-only and contains no service mutation', () {
    final source = File('scripts/hermes-mobile-setup.sh').readAsStringSync();
    expect(
      source,
      contains('systemctl --user is-active --quiet hermes-gateway.service'),
    );
    expect(source, contains('loopback and 0.0.0.0 are not reachable'));
    expect(source, isNot(contains('daemon-reload')));
    expect(source, isNot(contains('enable ')));
    expect(source, isNot(contains('restart ')));
  });

  test('buildPairingLink round-trips dashboard bridge and bridge token', () {
    final link = ServerSetupGenerator.buildPairingLink(
      host: '100.77.1.2',
      port: 8642,
      token: 'pair-token',
      dashboardUrl: 'http://100.77.1.2:9119',
      bridgeUrl: 'http://100.77.1.2:9131',
      bridgeToken: 'bridge-token',
    );
    final parsed = PairingLink.tryParse(link);
    expect(parsed, isNotNull);
    expect(parsed!.host, '100.77.1.2');
    expect(parsed.port, 8642);
    expect(parsed.token, 'pair-token');
    expect(parsed.dashboardUrl, 'http://100.77.1.2:9119');
    expect(parsed.bridgeUrl, 'http://100.77.1.2:9131');
    expect(parsed.bridgeToken, 'bridge-token');
  });

  test('pairing guidance remains short and refuses server secrets', () {
    final prompt = ServerSetupGenerator.agentPrompt;
    expect(prompt.length, lessThan(2000));
    expect(prompt, contains('Do not retrieve links, QR codes, tokens, keys'));
    expect(prompt, contains('Never ask the owner to paste them into chat'));
    expect(prompt, isNot(contains('API_SERVER_KEY=')));
    expect(prompt.toLowerCase(), isNot(contains('-----begin')));
  });
}
