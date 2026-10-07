import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../design/hermes_design.dart';

/// Acerca de: identidad de la app, estado del proyecto, atribuciones y
/// acceso a las licencias open source. Las licencias viven aquí a propósito
/// — no son una pantalla protagonista.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  /// Daeroh is a separate private downstream; never present the upstream
  /// developer's privacy policy or website as our own.
  static const _websiteUrl = 'https://github.com/ac-slay3r/Daeroh';

  static bool _appLicensesRegistered = false;

  static const _upstreamMitNotice = '''
hermes-android
https://github.com/rusty4444/hermes-android

The upstream project declares the MIT license in its README.

MIT License

Copyright (c) rusty4444 and hermes-android contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
''';

  String _version = '…';

  Future<void> _openLink(String url) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw Exception('launchUrl=false');
    } catch (e) {
      debugPrint('[about] no se pudo abrir $url: $e');
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).aboutLinkError)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  Future<void> _openPrivacyNote() async {
    final note = await rootBundle.loadString('docs/PRIVACY.md');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(Strings.of(dialogContext).aboutPrivacyPolicyTitle),
        content: SizedBox(width: 560, height: 440, child: Markdown(data: note)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              MaterialLocalizations.of(dialogContext).closeButtonLabel,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    if (!_appLicensesRegistered) {
      LicenseRegistry.addLicense(() async* {
        final projectLicense = await rootBundle.loadString('LICENSE');
        yield LicenseEntryWithLineBreaks(const [
          'Daeroh',
          'Hermes Console (upstream)',
        ], projectLicense);
        yield const LicenseEntryWithLineBreaks([
          'hermes-android (upstream)',
        ], _upstreamMitNotice);
        final fontLicense = await rootBundle.loadString('assets/fonts/OFL.txt');
        yield LicenseEntryWithLineBreaks(const [
          'Inter',
          'Nunito',
          'Montserrat',
          'JetBrains Mono',
        ], fontLicense);
      });
      _appLicensesRegistered = true;
    }
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = '${info.version}+${info.buildNumber}');
    } catch (e) {
      debugPrint(
        '[about] excepción silenciada (se avisa al usuario y se sigue): $e',
      );
      if (mounted) setState(() => _version = '—');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return HermesPage(
      title: s.aboutScreenTitle,
      children: [
        // Identidad
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Row(
            children: [
              Image.asset(
                'assets/branding/daeroh_logo.png',
                width: 56,
                height: 56,
                // El master es 1024×1024; decodificar acotado al tamaño
                // mostrado (×3 de DPR) ahorra ~4 MB de bitmap.
                cacheWidth: 168,
                cacheHeight: 168,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) =>
                    Icon(Icons.auto_awesome, size: 40, color: colors.accent),
              ),
              const SizedBox(width: HermesSpace.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Daeroh',
                      style: HermesType.display.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    HermesStatusText(
                      label: 'v$_version',
                      meta: s.aboutReleaseStatus,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
          child: Text(
            s.aboutTagline,
            style: HermesType.text.copyWith(color: colors.textSecondary),
          ),
        ),
        HermesSectionHeader(s.aboutSectionLegal),
        HermesListGroup(
          children: [
            HermesListRow(
              icon: Icons.description_outlined,
              title: s.aboutLicensesTitle,
              subtitle: s.aboutThirdParty,
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Daeroh',
                applicationVersion: 'v$_version',
              ),
            ),
            HermesListRow(
              icon: Icons.fork_right_outlined,
              title: s.aboutBaseProject,
              subtitle: s.aboutAttributions,
              subtitleMaxLines: 3,
            ),
            HermesListRow(
              icon: Icons.visibility_off_outlined,
              iconColor: colors.success,
              title: s.aboutPrivacyTitle,
              subtitle: s.aboutPrivacyBody,
              subtitleMaxLines: 6,
            ),
          ],
        ),
        // Privacy note is bundled locally; the private repo cannot serve
        // recipients of a development APK without GitHub access.
        HermesSectionHeader(s.aboutSectionLinks),
        HermesListGroup(
          children: [
            HermesListRow(
              icon: Icons.language_outlined,
              title: s.aboutWebsiteTitle,
              subtitle: s.aboutWebsiteSub,
              trailing: Icon(
                Icons.open_in_new,
                size: 18,
                color: colors.textDisabled,
              ),
              onTap: () => _openLink(_websiteUrl),
            ),
            HermesListRow(
              icon: Icons.policy_outlined,
              title: s.aboutPrivacyPolicyTitle,
              subtitle: s.aboutPrivacyPolicySub,
              onTap: _openPrivacyNote,
            ),
          ],
        ),
        // Nota de compatibilidad
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 16, 6, 0),
          child: Text(
            s.aboutUnofficial,
            style: HermesType.support.copyWith(color: colors.textDisabled),
          ),
        ),
      ],
    );
  }
}
