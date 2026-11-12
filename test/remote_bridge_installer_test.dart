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
}
