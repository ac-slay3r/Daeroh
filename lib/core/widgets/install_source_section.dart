import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../services/install_source.dart';
import '../theme/app_theme.dart';

/// Settings → About: which channel delivers updates, a button to open it, and
/// why switching channel needs an uninstall (different signing keys).
class InstallSourceSection extends StatefulWidget {
  /// Test seam: skip the platform lookup.
  final InstallSource? initialSource;

  const InstallSourceSection({super.key, this.initialSource});

  @override
  State<InstallSourceSection> createState() => _InstallSourceSectionState();
}

class _InstallSourceSectionState extends State<InstallSourceSection> {
  InstallSource? _source;

  @override
  void initState() {
    super.initState();
    _source = widget.initialSource;
    if (_source == null) {
      InstallSourceInfo.detect().then((source) {
        if (mounted) setState(() => _source = source);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final source = _source;
    final updateUrl = source == null
        ? null
        : InstallSourceInfo.updateUrl(source);
    final label = switch (source) {
      InstallSource.googlePlay => s.aboutUpdatesPlay,
      InstallSource.githubObtainium => s.aboutUpdatesGithub,
      InstallSource.manual => s.aboutUpdatesManual,
      null => '…',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesListGroup(
          children: [
            HermesListRow(
              key: const ValueKey('install-source-row'),
              icon: Icons.system_update_alt_rounded,
              title: s.aboutUpdatesTitle,
              value: label,
              showChevron: false,
            ),
            if (updateUrl != null)
              HermesListRow(
                key: const ValueKey('install-source-open'),
                icon: Icons.open_in_new_rounded,
                title: s.aboutUpdatesOpenReleases,
                onTap: () => launchUrl(
                  Uri.parse(updateUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
          child: Text(
            updateUrl == null
                ? s.aboutUpdatesNotConfigured
                : s.aboutUpdatesSwitchNote,
            style: HermesType.support.copyWith(
              color: Theme.of(context).hermes.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
