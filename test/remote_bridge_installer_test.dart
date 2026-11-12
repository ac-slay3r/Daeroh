import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_release_channel.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/remote_bridge_installer.dart';

void main() {
  test('remote releases are disabled', () async {
    final api = ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'synthetic',
    );
    final connection = SavedConnection(
      id: 'id',
      label: 'fixture',
      host: '100.100.100.100',
      port: 8642,
      apiKey: 'synthetic',
    );
    final installer = RemoteBridgeInstaller(api, connection);
    const release = BridgeRelease(
      version: '1.0.0',
      source: 'VERSION = "1.0.0"\n',
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      remote: true,
    );
    await expectLater(
      installer.installScript(release: release),
      throwsA(isA<UnsupportedError>()),
    );
    api.close();
  });

  test(
    'packaged bridge rollback restores program, env and unit after failed start',
    () async {
      if (Platform.isWindows) return;
      final root = Directory.systemTemp.createTempSync(
        'packaged-bridge-rollback-',
      );
      final hermesHome = Directory('${root.path}/hermes')..createSync();
      final configHome = Directory('${root.path}/config')..createSync();
      final unitDir = Directory('${configHome.path}/systemd/user')
        ..createSync(recursive: true);
      const oldSource = 'VERSION = "1.16.0"\n';
      const oldEnv =
          'BRIDGE_HOST=0.0.0.0\nBRIDGE_TOKEN=old\nBRIDGE_PORT=9131\n';
      const oldUnit = '[Unit]\nDescription=old bridge\n';
      final target = File('${hermesHome.path}/hermes_bridge.py')
        ..writeAsStringSync(oldSource);
      final envFile = File('${hermesHome.path}/bridge.env')
        ..writeAsStringSync(oldEnv);
      final unitFile = File('${unitDir.path}/hermes-bridge.service')
        ..writeAsStringSync(oldUnit);
      File(
        '${hermesHome.path}/.env',
      ).writeAsStringSync('API_SERVER_KEY=test-key\n');
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'synthetic',
      );
      try {
        const release = BridgeRelease(
          version: '1.17.0',
          source: 'VERSION = "1.17.0"\n',
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          remote: false,
        );
        final script = await RemoteBridgeInstaller(
          api,
          SavedConnection(
            id: 'id',
            label: 'fixture',
            host: '100.100.100.100',
            port: 8642,
            apiKey: 'synthetic',
          ),
        ).installScript(release: release);
        final result = await Process.run(
          'sh',
          [
            '-c',
            '''systemctl() {
  case "\$*" in
    *"restart hermes-bridge"*) return 1 ;;
    *) return 0 ;;
  esac
}
$script''',
          ],
          environment: {
            'HERMES_HOME': hermesHome.path,
            'XDG_CONFIG_HOME': configHome.path,
          },
        );
        expect(result.exitCode, isNonZero);
        expect(
          '${result.stdout}${result.stderr}',
          contains(RemoteBridgeInstaller.failMarker),
        );
        expect(target.readAsStringSync(), oldSource);
        expect(envFile.readAsStringSync(), oldEnv);
        expect(unitFile.readAsStringSync(), oldUnit);
      } finally {
        api.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
