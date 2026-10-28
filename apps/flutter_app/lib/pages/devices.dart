part of '../app.dart';

class _DevicesPage extends StatelessWidget {
  const _DevicesPage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _PageTitle(
          eyebrow: '',
          title: 'Devices',
          trailing: controller.canManageDevices || controller.devicesLoading
              ? FilledButton.tonalIcon(
                  onPressed: controller.working || !controller.canManageDevices
                      ? null
                      : () => _addDevice(context),
                  icon:
                      controller.devicesLoading && !controller.canManageDevices
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add device'),
                )
              : null,
        ),
        const SizedBox(height: 24),
        Text('THIS DEVICE', style: _eyebrowStyle(context)),
        const SizedBox(height: 9),
        _DeviceRow(
          name: controller.status?.deviceName ?? 'This device',
          platform: _platformLabel(),
          state: controller.status?.connection ?? 'offline',
          current: true,
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Text('PAIRED DEVICES', style: _eyebrowStyle(context)),
            const SizedBox(width: 8),
            Text('${controller.devices.length}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 9),
        if (controller.pairings.isNotEmpty) ...[
          for (final pairing in controller.pairings) ...[
            _PairingRequestTile(controller: controller, pairing: pairing),
            const SizedBox(height: 8),
          ],
        ],
        if (controller.devicesLoading && controller.devices.isEmpty)
          const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (controller.devices.isEmpty)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 64),
              child: _DevicesEmptyState(
                  onAdd: controller.canManageDevices
                      ? () => _addDevice(context)
                      : null))
        else
          for (final device in controller.devices) ...[
            _TrustedDeviceRow(
                device: device,
                onRemove: controller.canManageDevices && !device.isOwner
                    ? () => _confirmRemove(context, device)
                    : null),
            Divider(height: 1, color: theme.dividerColor),
          ],
        if (controller.error != null) ...[
          const SizedBox(height: 10),
          _InlineMessage(text: controller.error!, error: true),
        ],
      ],
    );
  }

  Future<void> _addDevice(BuildContext context) async {
    await controller.createInvite();
    if (!context.mounted) return;
    final invite = controller.invite;
    if (invite == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _InviteDialog(invite: invite, controller: controller),
    );
  }

  Future<void> _confirmRemove(BuildContext context, MeshDevice device) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${device.name}?'),
        content: const Text(
            'This device will lose access to future clips from your mesh.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton.tonal(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove device')),
        ],
      ),
    );
    if (remove == true) await controller.revokeDevice(device);
  }
}

class _DevicesEmptyState extends StatelessWidget {
  const _DevicesEmptyState({required this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              onAdd == null
                  ? 'No other devices are listed yet.'
                  : 'No paired devices yet.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (onAdd != null) ...[
              const SizedBox(height: 11),
              TextButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add a device')),
            ],
          ],
        ),
      );
}

class _PairingRequestTile extends StatelessWidget {
  const _PairingRequestTile({required this.controller, required this.pairing});

  final AppController controller;
  final PairingRequest pairing;

  @override
  Widget build(BuildContext context) {
    final inbound = pairing.direction == 'inbound';
    final awaitingConfirmation = pairing.state == 'awaiting_confirmation';
    final approved = pairing.state == 'approval_sent';
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 13, 13),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            awaitingConfirmation
                ? inbound
                    ? 'Confirm this device'
                    : 'Waiting for approval'
                : approved
                    ? 'Waiting for the other device'
                    : 'Pairing request ended',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Text(
            awaitingConfirmation
                ? inbound
                    ? '${pairing.peerName} wants to join your mesh. Compare the code on both screens.'
                    : '${pairing.peerName} must approve the same code before pairing is complete.'
                : approved
                    ? 'You approved this device. Pairing completes after the other device approves too.'
                    : 'Ask the mesh owner for a new invite to try again.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.35),
          ),
          if (pairing.verificationCode.isNotEmpty) ...[
            const SizedBox(height: 11),
            Text(
              pairing.verificationCode,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 1.4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (pairing.expiresAt case final expiresAt?) ...[
            const SizedBox(height: 5),
            Text(
              'Expires ${_relativeExpiry(expiresAt)}',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          if (inbound && awaitingConfirmation) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: controller.working
                      ? null
                      : () => controller.confirmPairing(pairing.sessionId,
                          accept: true),
                  child: const Text('Approve'),
                ),
                const SizedBox(width: 7),
                TextButton(
                  onPressed: controller.working
                      ? null
                      : () => controller.confirmPairing(pairing.sessionId,
                          accept: false),
                  child: const Text('Decline'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow(
      {required this.name,
      required this.platform,
      required this.state,
      this.current = false});

  final String name;
  final String platform;
  final String state;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        children: [
          _PlatformGlyph(platform: platform),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(platform,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          _PresenceLabel(state: state, current: current),
        ],
      ),
    );
  }
}

class _TrustedDeviceRow extends StatelessWidget {
  const _TrustedDeviceRow({required this.device, required this.onRemove});

  final MeshDevice device;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
      child: Row(
        children: [
          _PlatformGlyph(platform: device.platform),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                ListenableBuilder(
                    listenable: _RelativeClock.instance,
                    builder: (context, _) => Text(
                          '${device.platform}${device.lastSeen == null ? '' : ' · seen ${_relativeTime(device.lastSeen!)}'}',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        )),
              ],
            ),
          ),
          _PresenceLabel(state: device.state),
          if (onRemove != null)
            PopupMenuButton<String>(
              tooltip: 'Device actions',
              onSelected: (_) => onRemove!(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'remove', child: Text('Remove device'))
              ],
            ),
        ],
      ),
    );
  }
}

class _PlatformGlyph extends StatelessWidget {
  const _PlatformGlyph({required this.platform});

  final String platform;

  @override
  Widget build(BuildContext context) {
    final name = platform.toLowerCase();
    final icon =
        name.contains('ios') || name.contains('iphone') || name.contains('ipad')
            ? Icons.phone_iphone_rounded
            : name.contains('android')
                ? Icons.phone_android_rounded
                : name.contains('mac')
                    ? Icons.laptop_mac_rounded
                    : name.contains('linux')
                        ? Icons.computer_rounded
                        : name.contains('windows') || name.contains('pc')
                            ? Icons.desktop_windows_rounded
                            : Icons.devices_rounded;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon,
          size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

class _PresenceLabel extends StatelessWidget {
  const _PresenceLabel({required this.state, this.current = false});

  final String state;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final online = current ||
        state.toLowerCase() == 'online' ||
        state.toLowerCase() == 'connected';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle,
            size: 7, color: online ? colors.primary : colors.outline),
        const SizedBox(width: 6),
        Text(
          current
              ? 'This device'
              : online
                  ? 'Online'
                  : 'Offline',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}
