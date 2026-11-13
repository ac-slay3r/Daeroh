import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_release_channel.dart';

void main() {
  test(
    'always resolves the packaged bridge and makes no remote target',
    () async {
      const source = 'VERSION = "1.16.0"\n';
      final channel = BridgeReleaseChannel(
        loadPackagedSource: () async => source,
      );
      final release = await channel.resolve();
      expect(release.remote, isFalse);
      expect(release.source, source);
      expect(release.size, utf8.encode(source).length);
      expect((await channel.resolveTarget()).remote, isFalse);
    },
  );
}
