import 'package:material_ui/material_ui.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/shared/widgets/app_switch.dart';
import 'package:onexray/pages/shared/widgets/setting_row.dart';
import 'package:onexray/pages/theme/color.dart';
import 'package:onexray/pages/theme/font.dart';

/// App-managed ingress switches. The TUN tunnel and the local SOCKS port are
/// independent; the managed ingress follows the first enabled one.
class InboundModeCard extends StatefulWidget {
  const InboundModeCard({
    super.key,
    required this.tunEnabled,
    required this.socksEnabled,
    required this.socksPort,
    required this.keepConfigInbounds,
    required this.enabled,
    this.onTunChanged,
    this.onSocksChanged,
    this.onKeepConfigInboundsChanged,
    this.onSocksPortChanged,
  });

  final bool tunEnabled;
  final bool socksEnabled;
  final int socksPort;
  final bool keepConfigInbounds;
  final bool enabled;
  final ValueChanged<bool>? onTunChanged;
  final ValueChanged<bool>? onSocksChanged;
  final ValueChanged<bool>? onKeepConfigInboundsChanged;
  final ValueChanged<int>? onSocksPortChanged;

  @override
  State<InboundModeCard> createState() => _InboundModeCardState();
}

class _InboundModeCardState extends State<InboundModeCard> {
  late final TextEditingController _portController = TextEditingController(
    text: '${widget.socksPort}',
  );
  bool _invalidPort = false;

  @override
  void didUpdateWidget(InboundModeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.socksPort != widget.socksPort && !_invalidPort) {
      _portController.text = '${widget.socksPort}';
    }
  }

  void _submitPort() {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _invalidPort = true);
      return;
    }
    setState(() => _invalidPort = false);
    if (port != widget.socksPort) widget.onSocksPortChanged?.call(port);
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final palette = ColorManager.palette(context);
    return Card(
      key: const ValueKey('connection-inbound-mode'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.connectionTunnelModeTitle, style: AppTypography.panelTitle),
            const SizedBox(height: 4),
            Text(
              l.connectionTunnelModeDescription,
              style: AppTypography.supporting.copyWith(
                color: palette.mutedForeground,
              ),
            ),
            const SizedBox(height: 8),
            SettingRow(
              title: l.connectionTunMode,
              subtitle: l.connectionTunModeDescription,
              titleMaxLines: 4,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              trailing: AppSwitch(
                key: const ValueKey('connection-tun-switch'),
                value: widget.tunEnabled,
                enabled: widget.enabled,
                onChanged: widget.onTunChanged,
              ),
            ),
            SettingRow(
              title: l.connectionSocksPortMode,
              subtitle: l.connectionSocksPortModeDescription,
              titleMaxLines: 4,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              trailing: AppSwitch(
                key: const ValueKey('connection-socks-switch'),
                value: widget.socksEnabled,
                enabled: widget.enabled,
                onChanged: widget.onSocksChanged,
              ),
            ),
            if (widget.socksEnabled)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    Text(
                      l.connectionSocksPortLabel,
                      style: AppTypography.fieldLabel.copyWith(
                        color: palette.foreground,
                      ),
                    ),
                    TextField(
                      key: const ValueKey('connection-socks-port'),
                      controller: _portController,
                      enabled: widget.enabled,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.left,
                      keyboardType: TextInputType.number,
                      autocorrect: false,
                      style: AppTypography.settingsInput,
                      onSubmitted: (_) => _submitPort(),
                      onTapOutside: (_) {
                        FocusScope.of(context).unfocus();
                        _submitPort();
                      },
                      decoration: InputDecoration(
                        hintText: '10808',
                        errorText: _invalidPort
                            ? l.connectionInboundPortInvalid
                            : null,
                        errorMaxLines: 3,
                      ),
                    ),
                  ],
                ),
              ),
            SettingRow(
              title: l.connectionConfigInbounds,
              subtitle: l.connectionConfigInboundsDescription,
              titleMaxLines: 4,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              trailing: AppSwitch(
                key: const ValueKey('connection-config-inbounds-switch'),
                value: widget.keepConfigInbounds,
                enabled: widget.enabled,
                onChanged: widget.onKeepConfigInboundsChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
