part of '../app.dart';

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.invite, required this.controller});

  final PairingInvite invite;
  final AppController controller;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    final controller = widget.controller;
    final invite = controller.invite ?? widget.invite;
    final expired =
        invite.expiresAt != null && !invite.expiresAt!.isAfter(DateTime.now());
    // Laid out like showArcadeDialog, but rebuilt as the invite and pairing
    // requests change.
    return AlertDialog(
      scrollable: true,
      title: const Text('Invite a device'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                expired
                    ? 'This invite has expired. Create a new one to keep pairing.'
                    : 'On your other device, choose Join your other device, then scan this code or paste the invite.',
                style: ArcadeTokens.textBody.copyWith(color: c.muted),
              ),
              const SizedBox(height: ArcadeTokens.space16),
              Center(
                child: Opacity(
                  opacity: expired ? 0.3 : 1,
                  child: Container(
                    width: 224,
                    height: 224,
                    padding: const EdgeInsets.all(ArcadeTokens.space12),
                    decoration: BoxDecoration(
                      // QR codes scan reliably only dark-on-white, in both themes.
                      color: Colors.white,
                      borderRadius: const BorderRadius.all(
                          Radius.circular(ArcadeTokens.radiusLg)),
                      border: Border.all(color: c.line),
                    ),
                    child: QrImageView(
                      data: invite.invite,
                      version: QrVersions.auto,
                      gapless: false,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                      semanticsLabel: 'Invite QR code',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: ArcadeTokens.space10),
              Text(
                invite.expiresAt == null
                    ? 'This invite expires soon.'
                    : expired
                        ? 'Expired'
                        : 'Expires ${_relativeExpiry(invite.expiresAt!)}',
                textAlign: TextAlign.center,
                style: ArcadeTokens.textSmall
                    .copyWith(color: expired ? c.warn : c.faint),
              ),
              for (final pairing in controller.pairings
                  .where((value) => value.direction == 'inbound'))
                Padding(
                  padding: const EdgeInsets.only(top: ArcadeTokens.space12),
                  child: _PairingRequestTile(
                      controller: controller, pairing: pairing),
                ),
            ]),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actionsPadding: const EdgeInsets.fromLTRB(
          ArcadeTokens.space20, 0, ArcadeTokens.space20, ArcadeTokens.space20),
      actions: [
        Wrap(
            spacing: ArcadeTokens.space8,
            runSpacing: ArcadeTokens.space8,
            alignment: WrapAlignment.end,
            children: [
              if (expired)
                ArcadeButton(
                  label: 'Create new invite',
                  icon: 'refresh',
                  onPressed:
                      controller.working ? null : controller.createInvite,
                )
              else
                ArcadeButton(
                  label: 'Copy invite',
                  icon: 'copy',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: invite.invite));
                    if (context.mounted) {
                      showArcadeToast(context, 'Invite copied');
                    }
                  },
                ),
              ArcadeButton(
                  label: 'Done',
                  variant: ArcadeButtonVariant.primary,
                  onPressed: () => Navigator.pop(context)),
            ]),
      ],
    );
  }
}
