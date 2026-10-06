import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'arcade_widgets.dart';
import 'clipboard_widgets.dart';
import 'models.dart';
import 'services/app_controller.dart';
import 'services/invite_qr_decoder.dart';

const _pine = Color(0xFF386253);
const _ink = Color(0xFF242824);
const _canvas = Color(0xFFF6F7F5);
const _night = Color(0xFF141816);

class ArcadeApp extends StatefulWidget {
  const ArcadeApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<ArcadeApp> createState() => _ArcadeAppState();
}

class _ArcadeAppState extends State<ArcadeApp> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.start());
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Arcade Clipboard',
          themeMode: widget.controller.themeMode,
          theme: _lightTheme(),
          darkTheme: _darkTheme(),
          home: widget.controller.overlayOpen
              ? MeshOverlay(controller: widget.controller)
              : _AppHome(controller: widget.controller),
        ),
      );
}

ThemeData _lightTheme() {
  final colors = ColorScheme.fromSeed(
    seedColor: _pine,
    brightness: Brightness.light,
    surface: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    colorScheme: colors,
    scaffoldBackgroundColor: _canvas,
    dividerColor: const Color(0xFFE5E9E5),
    textTheme: ThemeData.light().textTheme.apply(
          bodyColor: _ink,
          displayColor: _ink,
          fontFamily: 'Inter',
        ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFEEF1EE),
      hintStyle:
          TextStyle(color: colors.onSurfaceVariant.withValues(alpha: 0.82)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide(color: colors.primary, width: 1.5),
      ),
    ),
  );
}

ThemeData _darkTheme() {
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFF82B7A0),
    brightness: Brightness.dark,
    surface: const Color(0xFF1D2420),
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    colorScheme: colors,
    scaffoldBackgroundColor: _night,
    dividerColor: const Color(0xFF303A34),
    textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF202823),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide(color: colors.primary, width: 1.5),
      ),
    ),
  );
}

enum _Section { clipboard, devices, settings }

class _AppHome extends StatefulWidget {
  const _AppHome({required this.controller});

  final AppController controller;

  @override
  State<_AppHome> createState() => _AppHomeState();
}

class _AppHomeState extends State<_AppHome> {
  _Section _section = _Section.clipboard;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.loading) return const _LoadingView();
    if (!controller.hasMesh) return _WelcomeView(controller: controller);

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 840;
      final body = _section == _Section.clipboard
          ? _ClipboardPage(
              controller: controller,
              onGoToDevices: () => _select(_Section.devices))
          : _section == _Section.devices
              ? _DevicesPage(controller: controller)
              : _SettingsPage(controller: controller);
      if (wide) {
        return Scaffold(
          body: Row(
            children: [
              _SideRail(
                controller: controller,
                selected: _section,
                onSelected: _select,
              ),
              VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
              Expanded(
                child: SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1060),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(34, 30, 34, 24),
                        child: body,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }

      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MobileHeader(controller: controller),
                const SizedBox(height: 25),
                Expanded(child: body),
              ],
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          height: 68,
          selectedIndex: _section.index,
          onDestinationSelected: (index) => _select(_Section.values[index]),
          destinations: [
            const NavigationDestination(
                icon: Icon(Icons.content_paste_rounded), label: 'Clipboard'),
            NavigationDestination(
              icon: controller.pairings.isEmpty
                  ? const Icon(Icons.devices_rounded)
                  : Badge(
                      label: Text('${controller.pairings.length}'),
                      child: const Icon(Icons.devices_rounded),
                    ),
              label: 'Devices',
            ),
            const NavigationDestination(
                icon: Icon(Icons.tune_rounded), label: 'Settings'),
          ],
        ),
      );
    });
  }

  void _select(_Section section) => setState(() => _section = section);
}

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.controller,
    required this.selected,
    required this.onSelected,
  });

  final AppController controller;
  final _Section selected;
  final ValueChanged<_Section> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        width: 212,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 27, 14, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _BrandLockup(compact: false),
              const SizedBox(height: 34),
              _NavItem(
                icon: Icons.content_paste_rounded,
                title: 'Clipboard',
                selected: selected == _Section.clipboard,
                onTap: () => onSelected(_Section.clipboard),
              ),
              _NavItem(
                icon: Icons.devices_rounded,
                title: 'Devices',
                trailing: controller.pairings.isNotEmpty
                    ? '${controller.pairings.length} pending'
                    : controller.devices.isEmpty
                        ? null
                        : '${controller.devices.length}',
                selected: selected == _Section.devices,
                onTap: () => onSelected(_Section.devices),
              ),
              _NavItem(
                icon: Icons.tune_rounded,
                title: 'Settings',
                selected: selected == _Section.settings,
                onTap: () => onSelected(_Section.settings),
              ),
              const Spacer(),
              if (controller.status?.paused == true)
                const _StatusPill(
                    label: 'Private mode',
                    icon: Icons.pause_rounded,
                    private: true)
              else
                _StatusPill(
                  label: _meshConnectionLabel(controller),
                  icon: _meshConnectionIcon(controller),
                ),
              const SizedBox(height: 13),
              Text(
                controller.status?.deviceName ?? 'This device',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const _BrandLockup(compact: true),
          const Spacer(),
          _StatusPill(
            label: controller.status?.paused == true
                ? 'Private mode'
                : _meshConnectionLabel(controller),
            icon: controller.status?.paused == true
                ? Icons.pause_rounded
                : _meshConnectionIcon(controller),
            private: controller.status?.paused == true,
          ),
        ],
      );
}

class _BrandLockup extends StatelessWidget {
  const _BrandLockup({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(Icons.copy_all_rounded,
              size: 19, color: theme.colorScheme.onPrimary),
        ),
        if (!compact) ...[
          const SizedBox(width: 11),
          Text('Arcade',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ],
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.09)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 46,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(icon, size: 19, color: color),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: selected ? theme.colorScheme.onSurface : color,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (trailing != null)
                    Text(trailing!,
                        style:
                            theme.textTheme.labelSmall?.copyWith(color: color)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(
      {required this.label, required this.icon, this.private = false});

  final String label;
  final IconData icon;
  final bool private;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: (private ? colors.tertiary : colors.primary)
            .withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 14, color: private ? colors.tertiary : colors.primary),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

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

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(height: 17),
              Text('Opening Arcade Clipboard…',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      );
}

class _ClipboardPage extends StatefulWidget {
  const _ClipboardPage({required this.controller, required this.onGoToDevices});

  final AppController controller;
  final VoidCallback onGoToDevices;

  @override
  State<_ClipboardPage> createState() => _ClipboardPageState();
}

class _ClipboardPageState extends State<_ClipboardPage> {
  final _search = TextEditingController();
  Timer? _searchTimer;
  String _kind = '';
  String _source = '';
  bool _pinnedOnly = false;

  @override
  void initState() {
    super.initState();
    _search.text = widget.controller.query ?? '';
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final allItems = controller.items;
    final items = allItems
        .where((item) =>
            (_kind.isEmpty || item.kind == _kind) &&
            (_source.isEmpty || item.originDevice == _source) &&
            (!_pinnedOnly || item.pinned))
        .toList();
    final filtered = _search.text.trim().isNotEmpty ||
        _kind.isNotEmpty ||
        _source.isNotEmpty ||
        _pinnedOnly;
    final sources = <String, String>{
      if (controller.status?.deviceId != null)
        controller.status!.deviceId!: 'This device',
      for (final device in controller.devices) device.id: device.name,
      for (final item in allItems) item.originDevice: item.sourceName
    };
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              _PageTitle(
                eyebrow: '',
                title: 'Clipboard',
                trailing: FilledButton.icon(
                  onPressed:
                      controller.working || controller.status?.paused == true
                          ? null
                          : () => showAddClip(context, controller),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add clip'),
                ),
              ),
              const SizedBox(height: 8),
              Text('Clips shared between your devices.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 22),
              TextField(
                controller: _search,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  hintText: 'Search clips',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _search.text.isNotEmpty
                      ? IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _search.clear();
                            _onSearch('');
                          },
                          icon: const Icon(Icons.close_rounded, size: 19))
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                      label: const Text('Pinned'),
                      selected: _pinnedOnly,
                      onSelected: (value) =>
                          setState(() => _pinnedOnly = value),
                      avatar: const Icon(Icons.push_pin_outlined, size: 15)),
                  PopupMenuButton<String>(
                    tooltip: 'Filter by content type',
                    onSelected: (value) => setState(() => _kind = value),
                    itemBuilder: (_) => [
                      for (final kind in const [
                        '',
                        'text',
                        'url',
                        'rich_text',
                        'image',
                        'file',
                        'files'
                      ])
                        PopupMenuItem(
                            value: kind,
                            child: Text(kind.isEmpty
                                ? 'All types'
                                : clipKindLabel(kind)))
                    ],
                    child: _FilterControl(
                        label:
                            _kind.isEmpty ? 'All types' : clipKindLabel(_kind)),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Filter by source device',
                    onSelected: (value) => setState(() => _source = value),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: '', child: Text('All devices')),
                      for (final source in sources.entries)
                        PopupMenuItem(
                            value: source.key, child: Text(source.value))
                    ],
                    child: _FilterControl(
                        label: _source.isEmpty
                            ? 'All devices'
                            : sources[_source] ?? 'Device'),
                  ),
                ],
              ),
              if (controller.error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child:
                        _InlineMessage(text: controller.error!, error: true)),
              if (controller.notice != null)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _InlineMessage(
                        text: controller.notice!,
                        onDismiss: controller.dismissNotice)),
              WaitingPhoto(controller: controller),
              LinkWorkStatus(controller: controller),
              if (controller.status?.paused == true)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _NoticeStrip(
                      icon: Icons.pause_circle_outline_rounded,
                      text:
                          'Sharing is paused. Existing clips are still available.',
                      actionLabel: 'Resume',
                      onAction: () => controller.setPrivatePause(false)),
                ),
              if (controller.status?.connection == 'offline' &&
                  controller.devices.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _NoticeStrip(
                      icon: Icons.cloud_off_rounded,
                      text:
                          'Offline. Clips will sync when your devices reconnect.',
                      actionLabel: 'Devices',
                      onAction: widget.onGoToDevices),
                ),
              const SizedBox(height: 16),
              if (controller.historyLoading)
                const LinearProgressIndicator(minHeight: 2),
            ])),
        if (items.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _ClipboardEmptyState(
              hasQuery: filtered,
              controller: controller,
              onAdd: () => showAddClip(context, controller),
              onClear: () {
                _search.clear();
                _onSearch('');
                setState(() {
                  _kind = '';
                  _source = '';
                  _pinnedOnly = false;
                });
              },
            ),
          )
        else
          SliverList(
              delegate: SliverChildBuilderDelegate((context, position) {
            if (position.isOdd) {
              return Divider(height: 1, color: theme.dividerColor);
            }
            final item = items[position ~/ 2];
            return _ClipboardRow(
              controller: controller,
              item: item,
              onTap: () => showClipDetail(context, controller, item),
              onCopy: () => controller.copyLocally(item),
              onPin: () => controller.setPinned(item, !item.pinned),
              onDelete: () => controller.deleteItem(item),
              onResend: () => controller.resendItem(item),
            );
          }, childCount: items.length * 2 - 1)),
        if (controller.hasMoreHistory)
          SliverToBoxAdapter(
              child: Center(
                  child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: TextButton(
                onPressed: controller.historyLoading
                    ? null
                    : controller.loadMoreHistory,
                child: const Text('Load more clips')),
          ))),
        SliverToBoxAdapter(
            child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            Text('${items.length} ${items.length == 1 ? 'clip' : 'clips'}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const Spacer(),
            if (controller.desktopCapabilities?.globalShortcut == true &&
                MediaQuery.sizeOf(context).width >= 1000)
              InkWell(
                  onTap: controller.openOverlay,
                  child: _KeyboardHint(shortcut: controller.shortcut)),
          ]),
        )),
      ],
    );
  }

  void _onSearch(String value) {
    setState(() {});
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 160),
        () => widget.controller.refreshHistory(query: value));
  }
}

class _FilterControl extends StatelessWidget {
  const _FilterControl({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(width: 8),
          const Icon(Icons.keyboard_arrow_down_rounded, size: 16)
        ]),
      );
}

class _ClipboardRow extends StatelessWidget {
  const _ClipboardRow(
      {required this.controller,
      required this.item,
      required this.onTap,
      required this.onCopy,
      required this.onPin,
      required this.onDelete,
      required this.onResend});
  final AppController controller;
  final ClipboardItem item;
  final VoidCallback onTap, onCopy, onPin, onDelete, onResend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 17),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: .65),
                  borderRadius: BorderRadius.circular(9)),
              child: item.kind == 'image'
                  ? ClipThumbnail(controller: controller, item: item)
                  : Icon(clipIcon(item.kind),
                      size: 19, color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(item.preview.isEmpty ? 'Empty clip' : item.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
                const SizedBox(height: 7),
                Text(
                    '${item.sourceName} · ${_relativeTime(item.createdAt)}${item.size > 0 && item.hasBinaryContent ? ' · ${formatBytes(item.size)}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ])),
          if (item.pinned)
            Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 0, 0),
                child: Icon(Icons.push_pin_rounded,
                    size: 15, color: theme.colorScheme.primary)),
          IconButton(
              tooltip: 'Copy to this device',
              onPressed: onCopy,
              icon: const Icon(Icons.copy_rounded, size: 17),
              visualDensity: VisualDensity.compact),
          PopupMenuButton<String>(
              tooltip: 'Clip actions',
              icon: const Icon(Icons.more_horiz_rounded, size: 19),
              onSelected: (action) {
                if (action == 'inspect') onTap();
                if (action == 'pin') onPin();
                if (action == 'delete') onDelete();
                if (action == 'resend') onResend();
                for (final offer in controller.linkActions(item)) {
                  if (action == 'link:${offer.peer}/${offer.action}') {
                    controller.invokeItemAction(item, offer);
                  }
                }
              },
              constraints: const BoxConstraints(minWidth: 240, maxWidth: 390),
              itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'inspect', child: Text('Inspect clip')),
                    PopupMenuItem(
                        value: 'pin',
                        child: Text(item.pinned ? 'Unpin clip' : 'Pin clip')),
                    const PopupMenuItem(
                        value: 'resend', child: Text('Share again')),
                    const PopupMenuItem(
                        value: 'delete', child: Text('Delete clip')),
                    for (final action in controller.linkActions(item))
                      PopupMenuItem(
                          value: 'link:${action.peer}/${action.action}',
                          enabled: action.enabled,
                          child: LinkActionLabel(action: action, item: item)),
                  ]),
        ]),
      ),
    );
  }
}

class _ClipboardEmptyState extends StatelessWidget {
  const _ClipboardEmptyState(
      {required this.hasQuery,
      required this.controller,
      required this.onAdd,
      required this.onClear});
  final bool hasQuery;
  final AppController controller;
  final VoidCallback onAdd, onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
        child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: .45),
              borderRadius: BorderRadius.circular(16)),
          child: Icon(
              hasQuery ? Icons.search_off_rounded : Icons.content_paste_rounded,
              size: 24,
              color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 18),
      Text(hasQuery ? 'No matching clips' : 'Your clipboard is empty',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Text(
              hasQuery
                  ? 'Try another search or clear the filters.'
                  : controller.automaticDesktopCapture
                      ? 'Copy text, an image, or a file to add it here.'
                      : 'Add a clip here, or share one to Arcade Clipboard from your phone.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.5))),
      const SizedBox(height: 17),
      TextButton.icon(
          onPressed: hasQuery
              ? onClear
              : controller.status?.paused == true
                  ? null
                  : onAdd,
          icon: Icon(
              hasQuery ? Icons.filter_alt_off_outlined : Icons.add_rounded,
              size: 18),
          label: Text(hasQuery ? 'Clear filters' : 'Add your first clip')),
    ])));
  }
}

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
                Text(
                  '${device.platform}${device.lastSeen == null ? '' : ' · seen ${_relativeTime(device.lastSeen!)}'}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
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

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.controller});

  final AppController controller;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  bool _recording = false;
  String? _shortcutDraft;
  String? _shortcutWarning;
  final FocusNode _shortcutFocus = FocusNode();

  @override
  void dispose() {
    _shortcutFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const _PageTitle(eyebrow: '', title: 'Settings'),
        const SizedBox(height: 28),
        if (controller.desktopAvailable) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.apps_rounded),
            title: const Text('Connected apps'),
            subtitle:
                const Text('Work with other Arcade apps on this desktop.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ConnectedAppsPage(controller: controller))),
          ),
          const SizedBox(height: 20),
        ],
        Text('PRIVACY', style: _eyebrowStyle(context)),
        const SizedBox(height: 8),
        _SettingLine(
          icon: Icons.pause_circle_outline_rounded,
          title: 'Private mode',
          description: 'Temporarily stop new clips from entering your mesh.',
          trailing: Switch.adaptive(
            value: controller.status?.paused ?? false,
            onChanged: controller.working ? null : controller.setPrivatePause,
          ),
        ),
        const Divider(height: 1),
        _SettingLine(
          icon: Icons.schedule_rounded,
          title: 'Keep history',
          description:
              'Unpinned clips expire after this time. Pinned clips stay until you unpin or delete them.',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _retentionValue(controller.retentionHours),
              items: const [
                DropdownMenuItem(value: 1, child: Text('1 hour')),
                DropdownMenuItem(value: 24, child: Text('24 hours')),
                DropdownMenuItem(value: 168, child: Text('7 days')),
                DropdownMenuItem(value: 720, child: Text('30 days')),
              ],
              onChanged: controller.working
                  ? null
                  : (value) {
                      if (value != null) controller.setRetentionHours(value);
                    },
            ),
          ),
        ),
        const Divider(height: 1),
        _SettingLine(
          icon: Icons.inventory_2_outlined,
          title: 'History limit',
          description:
              'Older clips are removed when the limit is reached. Pinned clips are kept first.',
          trailing: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
            value: const {500, 1000, 5000}.contains(controller.maxItems)
                ? controller.maxItems
                : 500,
            items: const [
              DropdownMenuItem(value: 500, child: Text('500 clips')),
              DropdownMenuItem(value: 1000, child: Text('1,000 clips')),
              DropdownMenuItem(value: 5000, child: Text('5,000 clips'))
            ],
            onChanged: controller.working
                ? null
                : (value) {
                    if (value != null) controller.setMaxItems(value);
                  },
          )),
        ),
        if (controller.desktopAvailable) ...[
          const SizedBox(height: 26),
          Text('DESKTOP', style: _eyebrowStyle(context)),
          const SizedBox(height: 8),
          if (controller.desktopAvailable)
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
          if (controller.desktopCapabilities?.globalShortcut == true)
            _SettingLine(
              icon: Icons.keyboard_command_key_rounded,
              title: 'Mesh Clipboard Shortcut',
              description: 'Open the clip picker over your current app.',
              trailing: TextButton(
                onPressed: controller.working ? null : _beginShortcutCapture,
                child: Text(_recording
                    ? 'Listening…'
                    : (_shortcutDraft ?? controller.shortcut)),
              ),
            )
          else
            _SettingLine(
              icon: Icons.keyboard_command_key_rounded,
              title: 'Mesh Clipboard Shortcut',
              description: controller.desktopAvailable
                  ? 'A global shortcut is not available on this desktop.'
                  : 'Available on desktop versions of Arcade Clipboard.',
              trailing: const Icon(Icons.info_outline_rounded, size: 20),
            ),
          if (_recording)
            Focus(
              focusNode: _shortcutFocus,
              onKeyEvent: _captureShortcut,
              child: Padding(
                padding: const EdgeInsets.only(left: 49, bottom: 10),
                child: Text(
                  'Press your preferred key combination. Esc cancels.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          if (_shortcutWarning != null)
            Padding(
              padding: const EdgeInsets.only(left: 49, bottom: 10),
              child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(_shortcutWarning!),
                    TextButton(
                        onPressed: () => _saveShortcut(_shortcutDraft!),
                        child: const Text('Use anyway')),
                    TextButton(
                        onPressed: () => setState(() {
                              _shortcutWarning = null;
                              _shortcutDraft = null;
                            }),
                        child: const Text('Cancel')),
                  ]),
            ),
          const Divider(height: 1),
        ],
        if (controller.desktopAvailable) ...[
          _SettingLine(
            icon: Icons.layers_outlined,
            title: 'Keep running in the background',
            description:
                'Closing the window keeps your mesh connected. Reopen Arcade from the tray.',
            trailing: Switch.adaptive(
                value: controller.backgroundEnabled,
                onChanged: controller.working
                    ? null
                    : controller.setBackgroundEnabled),
          ),
          _SettingLine(
            icon: Icons.power_settings_new_rounded,
            title: 'Launch at login',
            description: 'Start Arcade when you sign in to this device.',
            trailing: Switch.adaptive(
                value: controller.launchAtLogin,
                onChanged:
                    controller.working ? null : controller.setLaunchAtLogin),
          ),
          if (Platform.isMacOS &&
              controller.desktopCapabilities?.paste == false)
            _SettingLine(
                icon: Icons.accessibility_new_rounded,
                title: 'Allow automatic paste',
                description:
                    'macOS needs Accessibility access to paste into the app you were using.',
                trailing: TextButton(
                    onPressed: controller.requestPasteAccess,
                    child: const Text('Allow access'))),
        ],
        if (!controller.desktopAvailable) ...[
          const SizedBox(height: 26),
          Text('KEYBOARD & SHARING', style: _eyebrowStyle(context)),
          _SettingLine(
              icon: Icons.keyboard_outlined,
              title: 'Clipboard keyboard',
              description: Platform.isIOS
                  ? 'Enable Arcade Clipboard in Settings → General → Keyboard → Keyboards. Switch to it with the globe key to insert shared text.'
                  : 'Enable Arcade Clipboard in your system keyboard settings. Switch to it when you want to insert shared text.',
              trailing: TextButton(
                  onPressed: controller.openKeyboardSettings,
                  child: const Text('Keyboard settings'))),
          const _SettingLine(
              icon: Icons.ios_share_outlined,
              title: 'Share to your mesh',
              description:
                  'Select text, a link, or an image in another app. Open Share and choose Arcade Clipboard. Open Arcade to sync items waiting in your inbox.',
              trailing: SizedBox.shrink()),
        ],
        const SizedBox(height: 26),
        Text('APPEARANCE', style: _eyebrowStyle(context)),
        const SizedBox(height: 8),
        _SettingLine(
          icon: Icons.palette_outlined,
          title: 'Theme',
          description: 'Match your system or choose a fixed appearance.',
          trailing: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
            ],
            selected: {controller.themeMode},
            onSelectionChanged: (value) => controller.setThemeMode(value.first),
          ),
        ),
        const SizedBox(height: 26),
        Text('STATUS', style: _eyebrowStyle(context)),
        const SizedBox(height: 8),
        _SettingLine(
          icon: _meshConnectionIcon(controller),
          title: _meshConnectionLabel(controller),
          description: controller.status?.diagnostic.isNotEmpty == true
              ? controller.status!.diagnostic
              : 'Your clips are encrypted on this device before synchronization.',
          trailing: IconButton(
            tooltip: 'Refresh status',
            onPressed: controller.refreshAll,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        const SizedBox(height: 18),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 16),
          title: Text('Remote relay',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          subtitle: Text(
              controller.relayUrl.isEmpty
                  ? 'Local network only'
                  : 'Relay configured',
              style: theme.textTheme.bodySmall),
          children: [
            const Text(
                'A relay connects devices on different networks. Clipboard content stays encrypted. Use the address supplied with your deployment.'),
            const SizedBox(height: 12),
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                    onPressed: () => _editRelay(context),
                    icon: const Icon(Icons.edit_outlined, size: 17),
                    label: Text(controller.relayUrl.isEmpty
                        ? 'Configure relay'
                        : 'Edit relay'))),
          ],
        ),
        const SizedBox(height: 18),
        _SettingLine(
            icon: Icons.delete_outline_rounded,
            title: 'Clear history',
            description:
                'Remove unpinned clips from this device and your mesh.',
            trailing: TextButton(
                onPressed:
                    controller.working ? null : () => _clearHistory(context),
                child: Text('Clear',
                    style: TextStyle(color: theme.colorScheme.error)))),
        if (controller.error != null) ...[
          const SizedBox(height: 12),
          _InlineMessage(text: controller.error!, error: true),
        ],
        if (controller.notice != null) ...[
          const SizedBox(height: 8),
          _InlineMessage(text: controller.notice!),
        ],
      ],
    );
  }

  Future<void> _editRelay(BuildContext context) async {
    final field = TextEditingController(text: widget.controller.relayUrl);
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Remote relay'),
              content: SizedBox(
                  width: 420,
                  child: TextField(
                      controller: field,
                      autofocus: true,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                          labelText: 'Relay address',
                          hintText: 'wss://relay.example.com',
                          helperText:
                              'Leave empty to use only your local network.'))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, field.text),
                    child: const Text('Save'))
              ],
            ));
    // Let the dialog finish disposing its TextField before its controller.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    field.dispose();
    if (value != null) await widget.controller.setRelayUrl(value);
  }

  Future<void> _clearHistory(BuildContext context) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Clear unpinned history?'),
              content: const Text(
                  'Pinned clips stay. Deleted clips are removed from your paired devices when they reconnect.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton.tonal(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Clear history'))
              ],
            ));
    if (confirm == true) await widget.controller.clearHistory();
  }

  int _retentionValue(int hours) =>
      const {1, 24, 168, 720}.contains(hours) ? hours : 24;

  void _beginShortcutCapture() {
    setState(() {
      _recording = true;
      _shortcutDraft = null;
      _shortcutWarning = null;
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _shortcutFocus.requestFocus());
  }

  KeyEventResult _captureShortcut(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _recording = false);
      return KeyEventResult.handled;
    }
    if (_isModifier(event.logicalKey)) return KeyEventResult.handled;
    final parts = <String>[];
    final keyboard = HardwareKeyboard.instance;
    if (Platform.isMacOS && keyboard.isMetaPressed) {
      parts.add('CMD');
    } else if (keyboard.isControlPressed) {
      parts.add('CTRL');
    }
    if (keyboard.isAltPressed) parts.add('ALT');
    if (keyboard.isShiftPressed) parts.add('SHIFT');
    final key = _shortcutKeyName(event.logicalKey);
    if (parts.isEmpty || key.isEmpty || _isModifier(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    parts.add(key);
    final shortcut = parts.join('+');
    setState(() {
      _recording = false;
      _shortcutDraft = shortcut;
    });
    final owner = widget.controller.link.shortcutOwner(shortcut);
    if (owner != null) {
      setState(() => _shortcutWarning = 'Used by $owner');
    } else {
      _saveShortcut(shortcut);
    }
    return KeyEventResult.handled;
  }

  void _saveShortcut(String shortcut) {
    setState(() => _shortcutWarning = null);
    widget.controller.configureShortcut(shortcut).then((_) {
      if (mounted) setState(() => _shortcutDraft = null);
    });
  }

  bool _isModifier(LogicalKeyboardKey key) => {
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.controlRight,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.shiftRight,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.altRight,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.metaRight,
      }.contains(key);

  String _shortcutKeyName(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'SPACE';
    if (key == LogicalKeyboardKey.enter) return 'ENTER';
    if (key == LogicalKeyboardKey.tab) return 'TAB';
    if (key == LogicalKeyboardKey.backspace) return 'BACKSPACE';
    final label = key.keyLabel.toUpperCase();
    if (label.length == 1 || RegExp(r'^F\d{1,2}$').hasMatch(label)) {
      return label;
    }
    return '';
  }
}

class _SettingLine extends StatelessWidget {
  const _SettingLine({
    required this.icon,
    required this.title,
    required this.description,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 600;
      final content =
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 28,
            child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon,
                    size: 19, color: theme.colorScheme.onSurfaceVariant))),
        const SizedBox(width: 13),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(description,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.5)),
          if (narrow)
            Padding(padding: const EdgeInsets.only(top: 9), child: trailing),
        ])),
        if (!narrow) ...[const SizedBox(width: 24), trailing],
      ]);
      return Padding(
          padding: const EdgeInsets.symmetric(vertical: 17), child: content);
    });
  }
}

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

class MeshOverlay extends StatefulWidget {
  const MeshOverlay({super.key, required this.controller});

  final AppController controller;

  @override
  State<MeshOverlay> createState() => _MeshOverlayState();
}

class _MeshOverlayState extends State<MeshOverlay> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String? _selectedItemId;

  List<ClipboardItem> get _visible => widget.controller.overlayItems;

  int _selectedIndex(List<ClipboardItem> items) {
    if (items.isEmpty) return 0;
    final index = items.indexWhere((item) => item.id == _selectedItemId);
    return index < 0 ? 0 : index;
  }

  void _selectCurrent(List<ClipboardItem> items) {
    if (items.isEmpty) return;
    widget.controller.selectOverlayItem(items[_selectedIndex(items)]);
  }

  void _revealSelection(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      const rowExtent = 82.0;
      final rowTop = index * rowExtent;
      final rowBottom = rowTop + rowExtent;
      final viewportTop = _scroll.offset;
      final viewportBottom = viewportTop + _scroll.position.viewportDimension;
      final target = rowTop < viewportTop
          ? rowTop
          : rowBottom > viewportBottom
              ? rowBottom - _scroll.position.viewportDimension
              : null;
      if (target != null) {
        unawaited(_scroll.animateTo(
          target.clamp(0.0, _scroll.position.maxScrollExtent).toDouble(),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        ));
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _visible;
    final selectedIndex = _selectedIndex(items);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 17, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                          widget.controller.linkPickFor == null
                              ? 'Mesh Clipboard'
                              : 'Choose a clip for ${widget.controller.linkPickFor}',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: widget.controller.dismissOverlay,
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                CallbackShortcuts(
                    bindings: {
                      for (final key in const [
                        LogicalKeyboardKey.arrowUp,
                        LogicalKeyboardKey.arrowDown,
                        LogicalKeyboardKey.home,
                        LogicalKeyboardKey.end,
                        LogicalKeyboardKey.escape,
                        LogicalKeyboardKey.enter
                      ])
                        SingleActivator(key): () => _navigate(key)
                    },
                    child: TextField(
                      controller: _search,
                      focusNode: _focus,
                      onSubmitted: (_) => _selectCurrent(_visible),
                      onChanged: (value) {
                        setState(() => _selectedItemId = null);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
                        });
                        unawaited(widget.controller.searchOverlay(value));
                      },
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Search clips',
                        prefixIcon: Icon(Icons.search_rounded, size: 19),
                      ),
                    )),
                if (widget.controller.overlaySearchLoading)
                  const LinearProgressIndicator(minHeight: 2),
                LinkWorkStatus(controller: widget.controller),
                WaitingPhoto(controller: widget.controller),
                if (widget.controller.error != null)
                  Text(widget.controller.error!, maxLines: 2),
                if (widget.controller.notice != null)
                  Text(widget.controller.notice!, maxLines: 2),
                const SizedBox(height: 10),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Text(
                            _search.text.isEmpty
                                ? 'Your shared clipboard is empty.'
                                : 'No matching clips.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemExtent: 82,
                          itemCount: items.length,
                          itemBuilder: (context, index) => _OverlayClipRow(
                            item: items[index],
                            selected: index == selectedIndex,
                            onTap: () => widget.controller
                                .selectOverlayItem(items[index]),
                            onHover: (_) => setState(
                                () => _selectedItemId = items[index].id),
                          ),
                        ),
                ),
                Divider(height: 1, color: theme.dividerColor),
                if (items.isNotEmpty)
                  Wrap(spacing: 6, children: [
                    for (final action
                        in widget.controller.linkActions(items[selectedIndex]))
                      Tooltip(
                          message: action.disabledReason ??
                              items[selectedIndex].preview,
                          child: TextButton.icon(
                              icon: ArcadeGlyph(action.peer),
                              label: Text(
                                  '${action.title} ↗ · Ctrl+Alt+${action.shortcut}'),
                              onPressed: action.enabled
                                  ? () => widget.controller.invokeItemAction(
                                      items[selectedIndex], action)
                                  : null)),
                  ]),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const _KeyCap('↑'),
                    const SizedBox(width: 4),
                    const _KeyCap('↓'),
                    const SizedBox(width: 8),
                    Text('Select',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    const Spacer(),
                    const _KeyCap('Enter'),
                    const SizedBox(width: 6),
                    Text(
                        widget.controller.desktopCapabilities?.paste == true
                            ? 'Paste'
                            : 'Copy',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(width: 8),
                    const _KeyCap('Esc'),
                    const SizedBox(width: 6),
                    Text('Close',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _navigate(LogicalKeyboardKey key) => _handleKey(key);

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isAltPressed &&
        _visible.isNotEmpty) {
      final item = _visible[_selectedIndex(_visible)];
      for (final action in widget.controller.linkActions(item)) {
        if (event.logicalKey.keyLabel.toUpperCase() == action.shortcut &&
            action.enabled) {
          widget.controller.invokeItemAction(item, action);
          return KeyEventResult.handled;
        }
      }
    }
    return _handleKey(event.logicalKey);
  }

  KeyEventResult _handleKey(LogicalKeyboardKey key) {
    final items = _visible;
    if (key == LogicalKeyboardKey.escape) {
      widget.controller.dismissOverlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && items.isNotEmpty) {
      final next = (_selectedIndex(items) + 1) % items.length;
      setState(() => _selectedItemId = items[next].id);
      _revealSelection(next);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && items.isNotEmpty) {
      final previous =
          (_selectedIndex(items) - 1 + items.length) % items.length;
      setState(() => _selectedItemId = items[previous].id);
      _revealSelection(previous);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end) &&
        items.isNotEmpty) {
      final index = key == LogicalKeyboardKey.home ? 0 : items.length - 1;
      setState(() => _selectedItemId = items[index].id);
      _revealSelection(index);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter && items.isNotEmpty) {
      _selectCurrent(items);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

class _OverlayClipRow extends StatelessWidget {
  const _OverlayClipRow({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });

  final ClipboardItem item;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) => onHover(true),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Material(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    clipIcon(item.kind),
                    size: 18,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(height: 1.35)),
                        const SizedBox(height: 5),
                        Text(
                          '${item.sourceName}  ·  ${_relativeTime(item.createdAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageTitle extends StatelessWidget {
  const _PageTitle({required this.eyebrow, required this.title, this.trailing});

  final String eyebrow;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (eyebrow.isNotEmpty) ...[
                Text(eyebrow, style: _eyebrowStyle(context)),
                const SizedBox(height: 5)
              ],
              Text(title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600, letterSpacing: -0.5)),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _KeyboardHint extends StatelessWidget {
  const _KeyboardHint({required this.shortcut});

  final String shortcut;

  @override
  Widget build(BuildContext context) {
    final parts = shortcut.split('+');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Open mesh clipboard',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(width: 9),
        for (final part in parts) ...[
          _KeyCap(part),
          if (part != parts.last) const SizedBox(width: 3),
        ],
      ],
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall?.copyWith(fontSize: 10)),
    );
  }
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage(
      {required this.text, this.error = false, this.onDismiss});

  final String text;
  final bool error;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: (error ? colors.error : colors.primary).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
              error
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              size: 17,
              color: error ? colors.error : colors.primary),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(height: 1.4))),
          if (onDismiss != null)
            IconButton(
                onPressed: onDismiss,
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close_rounded, size: 16),
                visualDensity: VisualDensity.compact),
        ],
      ),
    );
  }
}

class _NoticeStrip extends StatelessWidget {
  const _NoticeStrip(
      {required this.icon,
      required this.text,
      required this.actionLabel,
      required this.onAction});

  final IconData icon;
  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 7, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}

TextStyle? _eyebrowStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 1.05,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );

String _relativeTime(DateTime time) {
  final difference = DateTime.now().difference(time);
  if (difference.isNegative || difference.inSeconds < 30) return 'just now';
  if (difference.inMinutes < 1) return '${difference.inSeconds}s ago';
  if (difference.inHours < 1) return '${difference.inMinutes}m ago';
  if (difference.inDays < 1) return '${difference.inHours}h ago';
  if (difference.inDays == 1) return 'yesterday';
  return '${difference.inDays}d ago';
}

String _relativeExpiry(DateTime time) {
  final remaining = time.difference(DateTime.now());
  if (remaining.isNegative || remaining.inSeconds == 0) return 'now';
  if (remaining.inMinutes < 1) return 'in ${remaining.inSeconds}s';
  if (remaining.inHours < 1) return 'in ${remaining.inMinutes}m';
  if (remaining.inDays < 1) return 'in ${remaining.inHours}h';
  if (remaining.inDays == 1) return 'in 1 day';
  return 'in ${remaining.inDays} days';
}

String _meshConnectionLabel(AppController controller) {
  if (controller.hasMesh && controller.devices.isEmpty) return 'Ready';
  if (controller.status?.connection == 'online') {
    if (controller.status?.transport == 'lan') return 'Local network';
    if (controller.status?.transport == 'relay') return 'Relay connected';
  }
  return _connectionLabel(controller.status?.connection ?? 'offline');
}

IconData _meshConnectionIcon(AppController controller) =>
    controller.hasMesh && controller.devices.isEmpty
        ? Icons.check_circle_outline_rounded
        : _connectionIcon(controller.status?.connection ?? 'offline');

IconData _connectionIcon(String value) {
  final normalized = value.toLowerCase();
  if (normalized == 'online' ||
      normalized == 'connected' ||
      normalized == 'lan' ||
      normalized == 'relay') {
    return Icons.cloud_done_rounded;
  }
  if (normalized.contains('connect')) return Icons.sync_rounded;
  return Icons.cloud_off_rounded;
}

String _connectionLabel(String value) {
  final normalized = value.toLowerCase();
  if (normalized == 'online' ||
      normalized == 'connected' ||
      normalized == 'lan' ||
      normalized == 'relay') {
    return 'Connected';
  }
  if (normalized.contains('connect')) return 'Connecting';
  return 'Offline';
}

String _platformLabel() => switch (Platform.operatingSystem) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      'ios' => 'iOS',
      'android' => 'Android',
      _ => 'This device',
    };

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
