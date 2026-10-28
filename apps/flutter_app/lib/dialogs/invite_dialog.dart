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
    final theme = Theme.of(context);
    final invite = widget.controller.invite ?? widget.invite;
    final expired =
        invite.expiresAt != null && !invite.expiresAt!.isAfter(DateTime.now());
    return AlertDialog(
      scrollable: true,
      title: const Text('Add a device'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(expired
                ? 'This invite has expired. Close this code and create a new invite.'
                : 'On your other device, choose Join an existing mesh. Scan this code or paste the invite.'),
            const SizedBox(height: 19),
            Container(
              width: 224,
              height: 224,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(18)),
              child: QrImageView(
                data: invite.invite,
                version: QrVersions.auto,
                gapless: false,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
            const SizedBox(height: 13),
            Text(
              invite.expiresAt == null
                  ? 'This invite expires soon.'
                  : 'Expires ${_relativeExpiry(invite.expiresAt!)}',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 13),
            if (expired)
              TextButton.icon(
                  onPressed: widget.controller.working
                      ? null
                      : widget.controller.createInvite,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Create new invite')),
            for (final pairing in widget.controller.pairings
                .where((value) => value.direction == 'inbound'))
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _PairingRequestTile(
                      controller: widget.controller, pairing: pairing)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: expired
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: invite.invite));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Invite copied.'),
                        duration: Duration(seconds: 2)));
                  }
                },
          child: const Text('Copy invite'),
        ),
        FilledButton(
            onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
