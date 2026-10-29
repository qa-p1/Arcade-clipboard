part of '../app.dart';

class _DevicesPage extends StatelessWidget {
  const _DevicesPage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final (syncLabel, syncTone) = _syncState(controller);
    final canInvite = controller.canManageDevices && !controller.working;
    return _PageFrame(children: [
      ArcadePageHead(
        title: 'Devices',
        subtitle:
            'Devices in your mesh share clips with each other, end-to-end encrypted.',
        actions: [
          if (controller.canManageDevices || controller.devicesLoading)
            ArcadeButton(
              label: 'Invite a device',
              icon: 'plus',
              variant: ArcadeButtonVariant.primary,
              busy: controller.devicesLoading && !controller.canManageDevices,
              onPressed: canInvite ? () => _addDevice(context) : null,
            ),
        ],
      ),
      _Messages(controller: controller),
      ArcadeListSection(title: 'This device', children: [
        ArcadeRow(
          title: controller.status?.deviceName ?? 'This device',
          subtitle: _platformLabel(),
          leading: _PlatformGlyph(platform: _platformLabel()),
          trailing: ArcadeBadge(syncLabel, tone: syncTone, dot: true),
        ),
      ]),
      if (controller.pairings.isNotEmpty) ...[
        _sectionGap,
        ArcadeListSection(
            title: 'Pairing requests',
            meta: formatCount(controller.pairings.length),
            children: [
              for (final pairing in controller.pairings)
                _PairingRequestTile(controller: controller, pairing: pairing),
            ]),
      ],
      _sectionGap,
      if (controller.devicesLoading && controller.devices.isEmpty)
        const ArcadeListSection(
            title: 'Trusted devices',
            children: [ArcadeSkeletonRow(), ArcadeSkeletonRow()])
      else if (controller.devices.isEmpty)
        ArcadeEmptyState(
          icon: 'monitor',
          title: 'No other devices yet',
          message: controller.canManageDevices
              ? 'Invite your phone or another computer to share clips between them.'
              : 'Devices the mesh owner adds show up here.',
          actions: [
            if (controller.canManageDevices)
              ArcadeButton(
                  label: 'Invite a device',
                  icon: 'plus',
                  onPressed: canInvite ? () => _addDevice(context) : null),
          ],
        )
      else
        ArcadeListSection(
            title: 'Trusted devices',
            meta: formatCount(controller.devices.length),
            children: [
              for (final device in controller.devices)
                _TrustedDeviceRow(
                  device: device,
                  onRemove: controller.canManageDevices && !device.isOwner
                      ? () => _confirmRemove(context, device)
                      : null,
                ),
            ]),
    ]);
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
    final remove = await confirmArcadeDestroy(
      context,
      title: 'Remove “${device.name}”?',
      message:
          'It stops receiving clips from your mesh. Clips it already has stay on it.',
      confirmLabel: 'Remove device',
    );
    if (remove) await controller.revokeDevice(device);
  }
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
    final title = awaitingConfirmation
        ? inbound
            ? 'Allow ${pairing.peerName}?'
            : 'Waiting for approval'
        : approved
            ? 'Waiting for the other device'
            : 'Pairing request ended';
    final message = awaitingConfirmation
        ? inbound
            ? '${pairing.peerName} wants to join your mesh. Check that both screens show the same code.'
            : '${pairing.peerName} must approve the same code before pairing is complete.'
        : approved
            ? 'You approved this device. Pairing completes after the other device approves too.'
            : 'Ask the mesh owner for a new invite to try again.';
    return Padding(
      padding: const EdgeInsets.all(ArcadeTokens.space12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ArcadeNotice(message,
            title: title,
            tone: awaitingConfirmation && inbound
                ? ArcadeTone.warn
                : ArcadeTone.neutral),
        if (pairing.verificationCode.isNotEmpty) ...[
          const SizedBox(height: ArcadeTokens.space10),
          _VerificationCode(code: pairing.verificationCode),
        ],
        if (pairing.expiresAt case final expiresAt?)
          Padding(
            padding: const EdgeInsets.only(top: ArcadeTokens.space6),
            child: ListenableBuilder(
              listenable: _RelativeClock.instance,
              builder: (context, _) => Text(
                  'Expires ${_relativeExpiry(expiresAt)}',
                  style: ArcadeTokens.textSmall
                      .copyWith(color: arcadeColors(context).muted)),
            ),
          ),
        if (inbound && awaitingConfirmation) ...[
          const SizedBox(height: ArcadeTokens.space10),
          Wrap(
              spacing: ArcadeTokens.space8,
              alignment: WrapAlignment.end,
              children: [
                ArcadeButton(
                  label: 'Decline',
                  onPressed: controller.working
                      ? null
                      : () => controller.confirmPairing(pairing.sessionId,
                          accept: false),
                ),
                ArcadeButton(
                  label: 'Allow',
                  variant: ArcadeButtonVariant.primary,
                  onPressed: controller.working
                      ? null
                      : () => controller.confirmPairing(pairing.sessionId,
                          accept: true),
                ),
              ]),
        ],
      ]),
    );
  }
}

/// A verification code as key-chip style mono groups ("628 140").
class _VerificationCode extends StatelessWidget {
  const _VerificationCode({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    final groups = code.split(' ').where((group) => group.isNotEmpty).toList();
    return Semantics(
      label: 'Verification code $code',
      child: ExcludeSemantics(
        child: Wrap(spacing: ArcadeTokens.space8, children: [
          for (final group in groups)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: ArcadeTokens.space12,
                  vertical: ArcadeTokens.space6),
              decoration: BoxDecoration(
                color: c.panel,
                borderRadius: const BorderRadius.all(
                    Radius.circular(ArcadeTokens.radiusSm)),
                border: Border(
                  top: BorderSide(color: c.lineStrong),
                  left: BorderSide(color: c.lineStrong),
                  right: BorderSide(color: c.lineStrong),
                  bottom: BorderSide(color: c.lineStrong, width: 2),
                ),
              ),
              child: Text(group,
                  style: ArcadeTokens.textTitle.copyWith(
                    color: c.text,
                    fontFamilyFallback: ArcadeTokens.monoFallback,
                    letterSpacing: 2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ),
        ]),
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
    final online = device.state.toLowerCase() == 'online' ||
        device.state.toLowerCase() == 'connected';
    return ListenableBuilder(
      listenable: _RelativeClock.instance,
      builder: (context, _) => ArcadeRow(
        title: device.name,
        subtitle:
            '${device.platform}${device.lastSeen == null ? '' : ' · seen ${_relativeTime(device.lastSeen!).toLowerCase()}'}',
        leading: _PlatformGlyph(platform: device.platform),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          ArcadeBadge(online ? 'Online' : 'Offline',
              tone: online ? ArcadeTone.ok : ArcadeTone.neutral, dot: online),
          if (onRemove != null)
            PopupMenuButton<String>(
              tooltip: 'Device actions',
              icon: ArcadeIcon('more', color: arcadeColors(context).muted),
              onSelected: (_) => onRemove!(),
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'remove',
                    child: Text('Remove device',
                        style: TextStyle(color: arcadeColors(context).danger))),
              ],
            ),
        ]),
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
    final phone = name.contains('ios') ||
        name.contains('iphone') ||
        name.contains('ipad') ||
        name.contains('android');
    return ArcadeGlyphTile(
      child: phone
          ? Icon(Icons.smartphone_outlined,
              size: ArcadeTokens.iconSize, color: arcadeColors(context).muted)
          : const ArcadeIcon('monitor'),
    );
  }
}
