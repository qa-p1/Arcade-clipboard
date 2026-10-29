part of '../app.dart';

enum _Setup { choose, start, join }

/// Welcome and pairing (STANDARD §5.1 onboarding): the kit hero, then two
/// choices as cards, "Start on this device" and "Join your other device".
class _WelcomeView extends StatefulWidget {
  const _WelcomeView({required this.controller});

  final AppController controller;

  @override
  State<_WelcomeView> createState() => _WelcomeViewState();
}

class _WelcomeViewState extends State<_WelcomeView> {
  final _deviceName = TextEditingController();
  final _invite = TextEditingController();
  final _qrDecoder = InviteQrDecoder();
  _Setup _setup = _Setup.choose;
  bool _importingQr = false;
  String? _qrImportError;

  @override
  void initState() {
    super.initState();
    _deviceName.text = widget.controller.status?.deviceName ?? Platform.localHostname;
  }

  @override
  void dispose() {
    _deviceName.dispose();
    _invite.dispose();
    super.dispose();
  }

  void _choose(_Setup setup) {
    setState(() => _setup = setup);
    if (setup == _Setup.join) unawaited(widget.controller.prepareToJoin());
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final c = arcadeColors(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(ArcadeTokens.space24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // The hero: 52 px mark, display title, one sentence.
                Center(
                  child: ArcadeGlyphTile(
                    size: ArcadeTokens.tileLg,
                    color: c.accent,
                    child: ArcadeIcon('clipboard', size: 26, color: c.accentText),
                  ),
                ),
                const SizedBox(height: ArcadeTokens.space16),
                Text('Set up Arcade Clipboard',
                    textAlign: TextAlign.center, style: ArcadeTokens.textDisplay.copyWith(color: c.text)),
                const SizedBox(height: ArcadeTokens.space8),
                Text(
                  'Copy on one of your devices and paste on another. No account, end-to-end encrypted.',
                  textAlign: TextAlign.center,
                  style: ArcadeTokens.textBody.copyWith(color: c.muted),
                ),
                const SizedBox(height: ArcadeTokens.space32),
                if (_setup == _Setup.choose)
                  LayoutBuilder(builder: (context, constraints) {
                    final cards = [
                      _ChoiceCard(
                        icon: 'plus',
                        title: 'Start on this device',
                        text: 'Create your mesh here, then invite your other devices.',
                        onTap: controller.working ? null : () => _choose(_Setup.start),
                      ),
                      _ChoiceCard(
                        icon: 'qr',
                        title: 'Join your other device',
                        text: 'Scan or paste the invite from a device that already uses Arcade Clipboard.',
                        onTap: controller.working ? null : () => _choose(_Setup.join),
                      ),
                    ];
                    return constraints.maxWidth >= 480
                        ? IntrinsicHeight(
                            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Expanded(child: cards[0]),
                            const SizedBox(width: ArcadeTokens.space12),
                            Expanded(child: cards[1]),
                          ]))
                        : Column(children: [cards[0], const SizedBox(height: ArcadeTokens.space12), cards[1]]);
                  })
                else
                  _setupForm(context),
                const SizedBox(height: ArcadeTokens.space16),
                if (controller.working) const LinearProgressIndicator(minHeight: 2),
                _Messages(controller: controller),
                if (controller.error != null && !controller.ready)
                  Center(
                    child: ArcadeButton(
                      label: 'Try again',
                      icon: 'refresh',
                      onPressed: controller.working ? null : () => controller.start(),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _setupForm(BuildContext context) {
    final controller = widget.controller;
    final join = _setup == _Setup.join;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ArcadeListSection(title: join ? 'Join your other device' : 'Start on this device', children: [
        ArcadeRow(
          title: 'Device name',
          subtitle: 'Helps you recognise this device on the others.',
          extra: TextField(
            controller: _deviceName,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(hintText: 'e.g. Studio Mac'),
          ),
        ),
        if (!join && controller.desktopAvailable)
          ArcadeSwitchRow(
            title: 'Add what you copy on this computer',
            subtitle: 'Text, images and files you copy are added and synced. Use Private mode for anything you don’t want shared.',
            value: controller.automaticDesktopCapture,
            onChanged: controller.working ? null : controller.setAutomaticDesktopCapture,
          ),
        if (join)
          ArcadeRow(
            title: 'Invite',
            subtitle: 'On your other device, open Devices › Invite a device.',
            extra: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: ArcadeTokens.space8, runSpacing: ArcadeTokens.space8, children: [
                if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)
                  ArcadeButton(
                    label: 'Scan QR code',
                    icon: 'qr',
                    small: true,
                    onPressed: controller.working
                        ? null
                        : () async {
                            final value = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _PairingScanner()));
                            if (value != null && mounted) setState(() => _invite.text = value);
                          },
                  ),
                ArcadeButton(
                  label: _importingQr ? 'Reading QR image…' : 'Import QR image',
                  icon: 'image',
                  small: true,
                  busy: _importingQr,
                  onPressed: _importingQr ? null : _importQrImage,
                ),
              ]),
              const SizedBox(height: ArcadeTokens.space8),
              TextField(
                controller: _invite,
                minLines: 2,
                maxLines: 4,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(hintText: 'Or paste the invite shown on your other device'),
              ),
              if (_qrImportError != null) ...[
                const SizedBox(height: ArcadeTokens.space8),
                ArcadeNotice(_qrImportError!, tone: ArcadeTone.danger),
              ],
            ]),
          ),
      ]),
      if (join && controller.currentJoin != null) ...[
        const SizedBox(height: ArcadeTokens.space16),
        _JoinVerificationCard(controller: controller, pairing: controller.currentJoin!),
      ],
      const SizedBox(height: ArcadeTokens.space16),
      Wrap(alignment: WrapAlignment.end, spacing: ArcadeTokens.space8, children: [
        ArcadeButton(label: 'Back', variant: ArcadeButtonVariant.ghost, onPressed: controller.working ? null : () => _choose(_Setup.choose)),
        if (join)
          ArcadeButton(
            label: 'Join',
            variant: ArcadeButtonVariant.primary,
            onPressed: controller.working ? null : () => controller.joinMesh(invite: _invite.text, deviceName: _deviceName.text),
          )
        else
          ArcadeButton(
            label: 'Start on this device',
            variant: ArcadeButtonVariant.primary,
            onPressed: controller.working ? null : () => controller.createMesh(_deviceName.text),
          ),
      ]),
    ]);
  }

  Future<void> _importQrImage() async {
    setState(() {
      _importingQr = true;
      _qrImportError = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Pairing QR image',
            extensions: ['png', 'jpg', 'jpeg'],
            mimeTypes: ['image/png', 'image/jpeg'],
            // iOS and macOS filter by type identifier, not extension.
            uniformTypeIdentifiers: ['public.png', 'public.jpeg'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > InviteQrDecoder.maxFileBytes) {
        throw const FormatException('Choose an image under 5 MB.');
      }
      final invite = _qrDecoder.decode(await file.readAsBytes());
      _invite.text = invite;
      if (mounted) setState(() => _qrImportError = null);
    } catch (exception) {
      if (mounted) {
        setState(() {
          _qrImportError = exception is FormatException
              ? exception.message
              : "Couldn't read that image. Choose a PNG or JPEG with a pairing QR code.";
        });
      }
    } finally {
      if (mounted) setState(() => _importingQr = false);
    }
  }
}

/// A welcome choice: glyph tile, title, one sentence; the whole card clicks.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.icon, required this.title, required this.text, required this.onTap});

  final String icon;
  final String title;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: c.hover,
        child: Padding(
          padding: const EdgeInsets.all(ArcadeTokens.space16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ArcadeGlyphTile(child: ArcadeIcon(icon, color: c.accent)),
            const SizedBox(height: ArcadeTokens.space12),
            Text(title, style: ArcadeTokens.textHeading.copyWith(color: c.text)),
            const SizedBox(height: ArcadeTokens.space4),
            Text(text, style: ArcadeTokens.textSmall.copyWith(color: c.muted)),
          ]),
        ),
      ),
    );
  }
}

class _JoinVerificationCard extends StatelessWidget {
  const _JoinVerificationCard({required this.controller, required this.pairing});

  final AppController controller;
  final PairingRequest pairing;

  @override
  Widget build(BuildContext context) {
    final awaitingConfirmation = pairing.state == 'awaiting_confirmation';
    final approved = pairing.state == 'approval_sent';
    return ArcadeListSection(children: [
      Padding(
        padding: const EdgeInsets.all(ArcadeTokens.space12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ArcadeNotice(
            awaitingConfirmation
                ? 'Compare this code with ${pairing.peerName}. Allow only if both screens show the same code.'
                : approved
                    ? 'You allowed this device. Pairing completes after the other device allows it too.'
                    : 'Ask the mesh owner for a new invite to try again.',
            title: awaitingConfirmation
                ? 'Check the code'
                : approved
                    ? 'Waiting for the other device'
                    : 'Pairing request ended',
            tone: awaitingConfirmation ? ArcadeTone.warn : ArcadeTone.neutral,
          ),
          if (pairing.verificationCode.isNotEmpty) ...[
            const SizedBox(height: ArcadeTokens.space10),
            _VerificationCode(code: pairing.verificationCode),
          ],
          if (pairing.expiresAt case final expiresAt?)
            Padding(
              padding: const EdgeInsets.only(top: ArcadeTokens.space6),
              child: Text('Expires ${_relativeExpiry(expiresAt)}',
                  style: ArcadeTokens.textSmall.copyWith(color: arcadeColors(context).faint)),
            ),
          if (awaitingConfirmation) ...[
            const SizedBox(height: ArcadeTokens.space10),
            Wrap(alignment: WrapAlignment.end, spacing: ArcadeTokens.space8, children: [
              ArcadeButton(
                label: 'Cancel',
                onPressed: controller.working ? null : () => controller.confirmPairing(pairing.sessionId, accept: false),
              ),
              ArcadeButton(
                label: 'Allow',
                variant: ArcadeButtonVariant.primary,
                onPressed: controller.working ? null : () => controller.confirmPairing(pairing.sessionId, accept: true),
              ),
            ]),
          ],
        ]),
      ),
    ]);
  }
}

class _PairingScanner extends StatefulWidget {
  const _PairingScanner();
  @override
  State<_PairingScanner> createState() => _PairingScannerState();
}

class _PairingScannerState extends State<_PairingScanner> {
  final _camera = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _scanned = false;

  @override
  void dispose() {
    unawaited(_camera.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(ArcadeTokens.space20),
          child: Text('On your other device, open Devices › Invite a device, then point the camera at its QR code.',
              style: ArcadeTokens.textBody.copyWith(color: c.muted)),
        ),
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            MobileScanner(
              controller: _camera,
              errorBuilder: (_, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(ArcadeTokens.space24),
                  child: Text(
                    error.errorCode == MobileScannerErrorCode.permissionDenied
                        ? 'Camera access is off. Allow camera access in system settings, or go back and import a QR image.'
                        : "Couldn't start the camera. Go back and import a QR image instead.",
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              onDetect: (capture) {
                if (_scanned) return;
                for (final barcode in capture.barcodes) {
                  final value = barcode.rawValue?.trim();
                  if (value != null && value.isNotEmpty) {
                    _scanned = true;
                    Navigator.of(context).pop(value);
                    break;
                  }
                }
              },
            ),
            // The scanner frame in the accent.
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(ArcadeTokens.radiusLg)),
                    border: Border.all(color: c.accent, width: 3),
                  ),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: ArcadeTokens.space20),
      ]),
    );
  }
}
