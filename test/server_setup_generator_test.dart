import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    expect(source, isNot(contains('0.0.0.0')));
    expect(source, isNot(contains('daemon-reload')));
    expect(source, isNot(contains('enable ')));
    expect(source, isNot(contains('restart ')));
  });
}
