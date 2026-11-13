import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/server_setup_generator.dart';

void main() {
  test('Windows server pairing is explicitly disabled', () {
    expect(
      ServerSetupGenerator.setupCommandFor(ServerHostPlatform.windows),
      contains('Linux'),
    );
    expect(
      ServerSetupGenerator.pairCommandFor(ServerHostPlatform.windows),
      contains('Linux'),
    );
  });
}
