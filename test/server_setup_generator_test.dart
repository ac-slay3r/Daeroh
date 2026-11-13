import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/core/services/server_setup_generator.dart';

void main() {
  test('Linux commands download the commit-pinned scripts before execution', () {
    const origin =
        'https://raw.githubusercontent.com/ac-slay3r/Daeroh/ec1438ce2e60a8cbc35f13e8285d13d34df9cce5/scripts';
    final commands = <({String name, String command})>[
      (
        name: ServerSetupGenerator.setupScriptName,
        command: ServerSetupGenerator.curlCommand,
      ),
      (
        name: ServerSetupGenerator.pairScriptName,
        command: ServerSetupGenerator.pairCommand,
      ),
    ];

    for (final entry in commands) {
      expect(entry.command, contains('$origin/${entry.name}'));
      expect(entry.command, contains("--proto '=https'"));
      expect(entry.command, contains(ServerSetupGenerator.setupScriptSha256));
      expect(entry.command, contains('sha256sum -c -'));
      expect(
        entry.command.indexOf('sha256sum -c -'),
        lessThan(entry.command.indexOf(r'sh "$file"')),
      );
      expect(entry.command, isNot(matches(RegExp(r'\|\s*(?:sh|bash)\b'))));
    }
  });

  test('setup script origin is a raw GitHub URL pinned to a full commit', () {
    expect(
      ServerSetupGenerator.setupScriptOrigin,
      matches(
        RegExp(
          r'^https://raw\.githubusercontent\.com/ac-slay3r/Daeroh/[0-9a-f]{40}/scripts$',
        ),
      ),
    );
  });

  test('in-repository setup scripts match the embedded SHA-256 pin', () {
    for (final name in <String>[
      ServerSetupGenerator.setupScriptName,
      ServerSetupGenerator.pairScriptName,
    ]) {
      final bytes = File('scripts/$name').readAsBytesSync();
      expect(
        sha256.convert(bytes).toString(),
        ServerSetupGenerator.setupScriptSha256,
      );
    }
  });

  test(
    'tampered local download fails closed before script execution',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        'daeroh-setup-tamper-',
      );
      addTearDown(() => fixture.delete(recursive: true));
      final bin = Directory('${fixture.path}/bin')..createSync();
      final marker = File('${fixture.path}/executed');
      final curl = File('${bin.path}/curl');
      curl.writeAsStringSync('''#!/bin/sh
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '-o' ]; then
    printf 'touch -- "\$DAEROH_TAMPER_MARKER"\\n' > "\$2"
    exit 0
  fi
  shift
done
exit 2
''');
      await Process.run('chmod', ['700', curl.path]);

      final result = await Process.run(
        'sh',
        ['-c', ServerSetupGenerator.curlCommand],
        environment: <String, String>{
          ...Platform.environment,
          'PATH': '${bin.path}:${Platform.environment['PATH']}',
          'DAEROH_TAMPER_MARKER': marker.path,
        },
      );

      expect(result.exitCode, isNonZero);
      expect(marker.existsSync(), isFalse);
    },
  );

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
