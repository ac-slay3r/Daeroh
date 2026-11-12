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
    for (final name in [
      'systemctl',
      'hermes',
      'tailscale',
      'qrencode',
      'python3',
    ]) {
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
    expect(parsed!.host, '100.64.0.1');
    expect(parsed.port, 8642);
    expect(parsed.token, 'synthetic-contract-token');
    expect(parsed.dashboardUrl, isNull);
    expect(parsed.bridgeUrl, isNull);
    expect(parsed.bridgeToken, isNull);
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
  test('strict ranges and endpoint-auth contract are guarded', () async {
    final source = File('scripts/hermes-mobile-setup.sh').readAsStringSync();
    expect(source, contains('wrong not in (401, 403)'));
    expect(source, contains('not 200 <= right < 300'));
    expect(source, contains('HERMES_DASHBOARD_PORT'));
    expect(source, isNot(contains('bridge_token')));
    for (final host in [
      '10.attacker.example',
      '192.168.1.1.attacker.example',
      '100.100.100.100.attacker.example',
      '10.999.999.999',
      '203.0.113.2',
      '127.0.0.1',
      '0.0.0.0',
      '010.0.0.1',
    ]) {
      final root = await Directory.systemTemp.createTemp('daeroh-pair-host-');
      addTearDown(() => root.delete(recursive: true));
      final bin = Directory('${root.path}/bin')..createSync();
      final home = Directory('${root.path}/home')..createSync();
      File(
        '${home.path}/.env',
      ).writeAsStringSync('API_SERVER_KEY=synthetic\\n');
      for (final name in ['systemctl', 'hermes']) {
        final file = File('${bin.path}/$name')..writeAsStringSync(_fake(name));
        await _makeExecutable(file);
      }
      final result = await Process.run(
        'sh',
        ['scripts/hermes-mobile-setup.sh'],
        environment: {
          'PATH': '${bin.path}:${Platform.environment['PATH']}',
          'HERMES_HOME': home.path,
          'HERMES_PAIR_HOST': host,
        },
      );
      expect(result.exitCode, isNonZero, reason: host);
      expect(
        '${result.stdout}${result.stderr}',
        isNot(contains('hermes://pair?')),
      );
    }
  });

  test('synthetic key is absent from Python argv', () async {
    final root = await Directory.systemTemp.createTemp('daeroh-pair-argv-');
    addTearDown(() => root.delete(recursive: true));
    final bin = Directory('${root.path}/bin')..createSync();
    final home = Directory('${root.path}/home')..createSync();
    const key = 'synthetic-argv-secret';
    File(
      '${home.path}/.env',
    ).writeAsStringSync('export API_SERVER_KEY="$key"\\n');
    final captured = File('${root.path}/python-argv');
    for (final name in ['systemctl', 'hermes']) {
      final file = File('${bin.path}/$name')..writeAsStringSync(_fake(name));
      await _makeExecutable(file);
    }
    final python = File('${bin.path}/python3')
      ..writeAsStringSync('''
#!/bin/sh
printf "%s\\n" "\$@" > "\$PAIR_ARGS_FILE"
printf "hermes://pair?host=100.64.0.1&port=8642&token=synthetic-argv-secret&label=Daeroh\\n"
''');
    await _makeExecutable(python);
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
        'HERMES_PAIR_HOST': '100.64.0.1',
        'PAIR_ARGS_FILE': captured.path,
      },
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(captured.readAsStringSync(), isNot(contains(key)));
    expect(captured.readAsStringSync(), contains('.env'));
  });
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
  'tailscale' => '#!/bin/sh\necho 100.64.0.1\n',
  'qrencode' => '#!/bin/sh\ncat >/dev/null\n',
  'python3' =>
    '#!/bin/sh\nprintf "hermes://pair?host=100.64.0.1&port=8642&token=synthetic-contract-token&label=Daeroh\\n"\n',
  _ => '#!/bin/sh\nexit 1\n',
};
