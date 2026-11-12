import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/core/services/server_setup_generator.dart';

void main() {
  test('runtime lib sources contain no XPeta setup URL', () {
    final urls = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      urls.addAll(
        RegExp(
          r'''https?://[^\s'")]+''',
        ).allMatches(entity.readAsStringSync()).map((m) => m.group(0)!),
      );
    }
    expect(
      urls.where(
        (url) => RegExp(r'xP3ta|xpetalab', caseSensitive: false).hasMatch(url),
      ),
      isEmpty,
    );
  });

  test('Linux command verifies a downloaded script before execution', () {
    final command = ServerSetupGenerator.curlCommand;
    expect(command, contains('curl --fail'));
    expect(command, contains('sha256sum -c -'));
    expect(command, contains('sh "\$file"'));
    expect(command, isNot(contains('| sh "')));
    expect(command, isNot(contains('http://')));
    expect(
      ServerSetupGenerator.setupCommandFor(ServerHostPlatform.windows),
      contains('Linux'),
    );
  });

  test('real fixture script output round-trips through PairingLink', () async {
    if (!await _has('script')) return;
    final root = await Directory.systemTemp.createTemp('daeroh-pair-fixture-');
    addTearDown(() => root.delete(recursive: true));
    final bin = Directory('${root.path}/bin')..createSync();
    final home = Directory('${root.path}/home')..createSync();
    File(
      '${home.path}/.env',
    ).writeAsStringSync('API_SERVER_KEY=synthetic-contract-token\n');
    for (final name in ['systemctl', 'hermes', 'tailscale', 'qrencode']) {
      final fake = File('${bin.path}/$name')..writeAsStringSync(_fake(name));
      await _makeExecutable(fake);
    }
    final result = await Process.run(
      'script',
      [
        '-q',
        '-c',
        '${File('scripts/hermes-mobile-setup.sh').absolute.path} --show-link',
        '/dev/null',
      ],
      environment: {
        'PATH': '${bin.path}:${Platform.environment['PATH']}',
        'HERMES_HOME': home.path,
      },
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final match = RegExp(
      r'hermes://pair\?[^\s\r]+',
    ).firstMatch(result.stdout.toString());
    expect(match, isNotNull, reason: result.stdout.toString());
    final parsed = PairingLink.tryParse(match!.group(0)!);
    expect(parsed, isNotNull);
    expect(parsed!.host, '100.100.100.100');
    expect(parsed.port, 8642);
    expect(parsed.token, 'synthetic-contract-token');
    expect(parsed.dashboardUrl, 'http://100.100.100.100:9119');
    expect(parsed.bridgeUrl, 'http://100.100.100.100:9131');
    expect(parsed.bridgeToken, 'synthetic-contract-token');
    expect(parsed.label, 'Daeroh');
  });

  test(
    'failed precondition performs no writes and non-TTY stdout has no secret',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'daeroh-pair-negative-',
      );
      addTearDown(() => root.delete(recursive: true));
      final bin = Directory('${root.path}/bin')..createSync();
      final home = Directory('${root.path}/home')..createSync();
      File(
        '${home.path}/.env',
      ).writeAsStringSync('API_SERVER_KEY=synthetic-no-leak\n');
      final foreign = File('${home.path}/hermes-gateway.service')
        ..writeAsStringSync('foreign bytes\n');
      final before = await foreign.readAsBytes();
      for (final name in ['systemctl', 'hermes']) {
        final fake = File('${bin.path}/$name')
          ..writeAsStringSync(_fake(name, inactive: true));
        await _makeExecutable(fake);
      }
      final result = await Process.run(
        'sh',
        ['scripts/hermes-mobile-setup.sh'],
        environment: {
          'PATH': '${bin.path}:${Platform.environment['PATH']}',
          'HERMES_HOME': home.path,
        },
      );
      expect(result.exitCode, isNonZero);
      expect(await foreign.readAsBytes(), before);
      expect(
        '${result.stdout}${result.stderr}',
        isNot(contains('synthetic-no-leak')),
      );
      expect(Directory('${home.path}/console-services').existsSync(), isFalse);
    },
  );
}

Future<bool> _has(String command) async =>
    (await Process.run('sh', ['-c', 'command -v $command'])).exitCode == 0;

Future<void> _makeExecutable(File file) async {
  final result = await Process.run('chmod', ['700', file.path]);
  if (result.exitCode != 0) throw StateError('chmod failed');
}

String _fake(String name, {bool inactive = false}) => switch (name) {
  'systemctl' => '#!/bin/sh\n${inactive ? 'exit 3' : 'exit 0'}\n',
  'hermes' => '#!/bin/sh\nexit 0\n',
  'tailscale' => '#!/bin/sh\necho 100.100.100.100\n',
  'qrencode' => '#!/bin/sh\ncat >/dev/null\n',
  _ => '#!/bin/sh\nexit 1\n',
};
