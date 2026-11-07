import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where this build receives updates from. Play and GitHub/Obtainium builds
/// are signed with different keys, so Android refuses to update one with the
/// other ("App not installed") — switching channel requires uninstalling.
enum InstallSource { googlePlay, githubObtainium, manual }

abstract final class InstallSourceInfo {
  // Daeroh is not published on Play. Never route this package to upstream's
  // differently signed releases or Play listing.
  static const playListingUrl =
      'https://github.com/ac-slay3r/Daeroh/releases';
  static const githubReleasesUrl =
      'https://github.com/ac-slay3r/Daeroh/releases';

  static const _channel = MethodChannel('hermes/platform_info');

  /// Test seam: overrides the platform lookup.
  @visibleForTesting
  static Future<String?> Function()? installerOverride;

  /// Maps the Android installer package name to a channel.
  static InstallSource classify(String? installer) {
    switch (installer) {
      case 'com.android.vending':
      case 'com.google.android.feedback':
        return InstallSource.googlePlay;
      case 'dev.imranr.obtainium':
      case 'dev.imranr.obtainium.fdroid':
        return InstallSource.githubObtainium;
      default:
        return InstallSource.manual;
    }
  }

  static Future<InstallSource> detect() async {
    String? installer;
    try {
      installer = installerOverride != null
          ? await installerOverride!()
          : await _channel.invokeMethod<String>('getInstallerPackage');
    } catch (_) {
      installer = null;
    }
    return classify(installer);
  }

  static String updateUrl(InstallSource source) =>
      source == InstallSource.googlePlay ? playListingUrl : githubReleasesUrl;
}
