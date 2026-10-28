part of '../app.dart';

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
  bool _joining = false;
  bool _importingQr = false;

  @override
  void initState() {
    super.initState();
    _deviceName.text =
        widget.controller.status?.deviceName ?? Platform.localHostname;
  }

  String? _qrImportError;

  @override
  void dispose() {
    _deviceName.dispose();
    _invite.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 780;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: _welcomeCopy(context)),
                        const SizedBox(width: 70),
                        SizedBox(width: 370, child: _setupForm(context)),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _welcomeCopy(context),
                        const SizedBox(height: 38),
                        _setupForm(context),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _welcomeCopy(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _BrandLockup(compact: true),
        const SizedBox(height: 42),
        Text(
          'Set up Arcade Clipboard',
          style: theme.textTheme.displaySmall?.copyWith(
            height: 1.08,
            letterSpacing: -1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            'Share text, images, and files between your own devices. Pair a device once, then use the shared history to copy or paste a clip.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.55,
            ),
          ),
        ),
      ],
    );
  }

  Widget _setupForm(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Get started',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 7),
        Text(
          'No account needed. This name helps you recognize the device.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _deviceName,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
              labelText: 'Device name', hintText: 'e.g. Studio Mac'),
        ),
        if (controller.desktopAvailable) ...[
          const SizedBox(height: 16),
          _SettingLine(
            icon: Icons.content_paste_search_rounded,
            title: 'Automatically add desktop copies',
            description:
                'Adds copied text, images, and files. Use Private mode for anything you do not want shared.',
            trailing: Switch.adaptive(
              value: controller.automaticDesktopCapture,
              onChanged: controller.working
                  ? null
                  : controller.setAutomaticDesktopCapture,
            ),
          ),
        ],
        const SizedBox(height: 13),
        if (!_joining)
          FilledButton.icon(
            onPressed: controller.working
                ? null
                : () => controller.createMesh(_deviceName.text),
            icon: const Icon(Icons.add_link_rounded, size: 19),
            label: const Text('Create mesh'),
          )
        else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: 6, children: [
              if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)
                TextButton.icon(
                  onPressed: controller.working
                      ? null
                      : () async {
                          final value = await Navigator.of(context)
                              .push<String>(MaterialPageRoute(
                                  builder: (_) => const _PairingScanner()));
                          if (value != null && mounted) {
                            setState(() => _invite.text = value);
                          }
                        },
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: const Text('Scan QR code'),
                ),
              TextButton.icon(
                onPressed: _importingQr ? null : _importQrImage,
                icon: _importingQr
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.qr_code_2_rounded, size: 18),
                label: Text(
                    _importingQr ? 'Reading QR image…' : 'Import QR image'),
              ),
            ]),
          ),
          TextField(
            controller: _invite,
            minLines: 2,
            maxLines: 4,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Pairing invite',
              hintText: 'Paste the code shown on your other device',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 11),
          FilledButton.icon(
            onPressed: controller.working
                ? null
                : () => controller.joinMesh(
                    invite: _invite.text, deviceName: _deviceName.text),
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 19),
            label: const Text('Join this mesh'),
          ),
          if (_qrImportError != null) ...[
            const SizedBox(height: 9),
            _InlineMessage(text: _qrImportError!, error: true),
          ],
          if (controller.currentJoin case final pairing?) ...[
            const SizedBox(height: 13),
            _JoinVerificationCard(controller: controller, pairing: pairing),
          ],
        ],
        const SizedBox(height: 8),
        TextButton(
          onPressed: controller.working
              ? null
              : () {
                  setState(() => _joining = !_joining);
                  if (_joining) unawaited(controller.prepareToJoin());
                },
          child: Text(_joining ? 'Back' : 'Join an existing mesh'),
        ),
        if (controller.working) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (controller.error != null) ...[
          const SizedBox(height: 13),
          _InlineMessage(text: controller.error!, error: true),
        ],
        if (controller.notice != null) ...[
          const SizedBox(height: 13),
          _InlineMessage(text: controller.notice!),
        ],
        if (controller.error != null && !controller.ready)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: TextButton.icon(
              onPressed: controller.working ? null : () => controller.start(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry secure setup'),
            ),
          ),
      ],
    );
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
              : 'Could not read that image. Choose a PNG or JPEG with a pairing QR code.';
        });
      }
    } finally {
      if (mounted) setState(() => _importingQr = false);
    }
  }
}

class _JoinVerificationCard extends StatelessWidget {
  const _JoinVerificationCard(
      {required this.controller, required this.pairing});

  final AppController controller;
  final PairingRequest pairing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final awaitingConfirmation = pairing.state == 'awaiting_confirmation';
    final approved = pairing.state == 'approval_sent';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            awaitingConfirmation
                ? 'Verify this device'
                : approved
                    ? 'Waiting for the other device'
                    : 'Pairing request ended',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            awaitingConfirmation
                ? 'Compare this code with ${pairing.peerName}. Approve only if both screens show the same code.'
                : approved
                    ? 'You approved this device. Pairing completes after the other device approves too.'
                    : 'Ask the mesh owner for a new invite to try again.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          if (pairing.verificationCode.isNotEmpty) ...[
            const SizedBox(height: 10),
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
          if (awaitingConfirmation) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: controller.working
                      ? null
                      : () => controller.confirmPairing(pairing.sessionId,
                          accept: true),
                  child: const Text('Approve'),
                ),
                TextButton(
                  onPressed: controller.working
                      ? null
                      : () => controller.confirmPairing(pairing.sessionId,
                          accept: false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PairingScanner extends StatefulWidget {
  const _PairingScanner();
  @override
  State<_PairingScanner> createState() => _PairingScannerState();
}

class _PairingScannerState extends State<_PairingScanner> {
  final _camera = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates);
  bool _scanned = false;

  @override
  void dispose() {
    unawaited(_camera.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan pairing code')),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                  'Open Add device on your other device, then point the camera at its QR code.',
                  style: Theme.of(context).textTheme.bodyMedium)),
          Expanded(
              child: MobileScanner(
            controller: _camera,
            errorBuilder: (_, error) => Center(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                        error.errorCode ==
                                MobileScannerErrorCode.permissionDenied
                            ? 'Camera access is off. Allow camera access in system settings, or go back and import a QR image.'
                            : 'The camera could not start. Go back and import a QR image instead.',
                        textAlign: TextAlign.center))),
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
          )),
          const SizedBox(height: 20),
        ]),
      );
}
