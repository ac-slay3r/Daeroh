import 'pairing_link.dart';

/// Operating system of the computer that runs Hermes Agent, not the phone.
enum ServerHostPlatform { linux, macos, windows }

/// Generates copy-only commands. The Linux command is intentionally fail-closed
/// until the owner chooses a Daeroh-controlled distribution origin.
class ServerSetupGenerator {
  const ServerSetupGenerator();

  static const int gatewayPort = 8642;
  static const int dashboardPort = 9119;
  static const int bridgePort = 9131;

  /// The sole distribution-origin input. It is intentionally not a URL while
  /// hosting/repository visibility remains an owner decision.
  static const String setupScriptOriginEnvironment = 'DAEROH_SETUP_ORIGIN';
  static const String setupScriptName = 'hermes-mobile-setup.sh';
  static const String pairScriptName = 'hermes-pair.sh';
  static const String setupScriptSha256 =
      '6222e0a2a012794e5e37264249c0a58885a15274770d72e34d3d05a552698f75';
  static const String pairScriptSha256 = setupScriptSha256;

  static String _verifiedDownloadCommand(String name, String sha256) =>
      'origin="\${$setupScriptOriginEnvironment:?set a Daeroh-controlled HTTPS origin}"; '
      'file="\$(mktemp)"; trap \'rm -f "\$file"\' EXIT; '
      'curl --fail --location --proto \'=https\' --tlsv1.2 "\$origin/$name" -o "\$file" && '
      'printf \'%s  %s\\n\' "$sha256" "\$file" | sha256sum -c - && sh "\$file"';

  static final String curlCommand = _verifiedDownloadCommand(
    setupScriptName,
    setupScriptSha256,
  );
  static final String pairCommand = _verifiedDownloadCommand(
    pairScriptName,
    pairScriptSha256,
  );

  static const String unsupportedPlatformCommand =
      'Daeroh server pairing currently supports Linux with systemd user services only.';

  static String setupCommandFor(ServerHostPlatform platform) =>
      platform == ServerHostPlatform.linux
      ? curlCommand
      : unsupportedPlatformCommand;
  static String pairCommandFor(ServerHostPlatform platform) =>
      platform == ServerHostPlatform.linux
      ? pairCommand
      : unsupportedPlatformCommand;

  static String buildPairingLink({
    required String host,
    required int port,
    required String token,
    bool useHttps = false,
    String? dashboardUrl,
    String? bridgeUrl,
    String? bridgeToken,
    String? label,
  }) => PairingLink(
    host: host,
    port: port,
    token: token,
    label: label,
    useHttps: useHttps,
    dashboardUrl: dashboardUrl,
    bridgeUrl: bridgeUrl,
    bridgeToken: bridgeToken,
  ).build();

  static String agentPromptFor(ServerHostPlatform platform) {
    final platformName = switch (platform) {
      ServerHostPlatform.windows => 'Windows',
      ServerHostPlatform.macos => 'macOS',
      ServerHostPlatform.linux => 'Linux',
    };
    return 'Read-only setup guidance for Daeroh on $platformName. Explain how '
        'the owner can prepare an existing Hermes server in a trusted terminal. '
        'Do not run commands, install, repair, configure, restart or expose '
        'services. Do not retrieve links, QR codes, tokens, keys, passwords, '
        'environment variables, configuration files or logs. Never ask the '
        'owner to paste them into chat. Do not construct pairing data.';
  }

  static final String agentPrompt = agentPromptFor(ServerHostPlatform.linux);
}
