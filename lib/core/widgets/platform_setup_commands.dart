import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../services/server_setup_generator.dart';
import '../theme/app_theme.dart';
import 'hermes_notice.dart';

/// Daeroh server pairing is deliberately Linux/systemd-user only.
class PlatformSetupCommands extends StatelessWidget {
  const PlatformSetupCommands({super.key, this.pairing = false});
  final bool pairing;

  @override
  Widget build(BuildContext context) {
    final str = Strings.of(context);
    final command = pairing
        ? ServerSetupGenerator.pairCommand
        : ServerSetupGenerator.curlCommand;
    return Column(
      children: [
        _PlatformCommand(
          label: '${str.setupPlatformLinux} / systemd user',
          command: command,
        ),
        const SizedBox(height: 8),
        Text('macOS and Windows server pairing are not supported yet.'),
      ],
    );
  }
}

class _PlatformCommand extends StatelessWidget {
  const _PlatformCommand({required this.label, required this.command});
  final String label;
  final String command;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 7),
          SelectableText(
            command,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: command));
                HermesNotice.of(context).showSnackBar(
                  SnackBar(content: Text(Strings.of(context).qrCmdCopied)),
                  kind: HermesNoticeKind.success,
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: Text(Strings.of(context).commonCopy),
            ),
          ),
        ],
      ),
    );
  }
}
