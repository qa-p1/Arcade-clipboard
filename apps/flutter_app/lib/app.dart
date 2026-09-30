import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
    colorScheme: colors,
    scaffoldBackgroundColor: _canvas,
    dividerColor: const Color(0xFFE5E9E5),
    textTheme: ThemeData.light().textTheme.apply(
          bodyColor: _ink,
          displayColor: _ink,
        ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFEEF1EE),
      hintStyle: TextStyle(color: colors.onSurfaceVariant.withValues(alpha: 0.82)),
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
    colorScheme: colors,
    scaffoldBackgroundColor: _night,
    dividerColor: const Color(0xFF303A34),
    textTheme: ThemeData.dark().textTheme,
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
          ? _ClipboardPage(controller: controller, onGoToDevices: () => _select(_Section.devices))
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
                        padding: const EdgeInsets.fromLTRB(42, 32, 42, 28),
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
            const NavigationDestination(icon: Icon(Icons.content_paste_rounded), label: 'Clipboard'),
            NavigationDestination(
              icon: controller.pairings.isEmpty
                  ? const Icon(Icons.devices_rounded)
                  : Badge(
                      label: Text('${controller.pairings.length}'),
                      child: const Icon(Icons.devices_rounded),
                    ),
              label: 'Devices',
            ),
            const NavigationDestination(icon: Icon(Icons.tune_rounded), label: 'Settings'),
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
        width: 236,
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
                const _StatusPill(label: 'Private mode', icon: Icons.pause_rounded, private: true)
              else
                _StatusPill(
                  label: _connectionLabel(controller.status?.connection ?? 'offline'),
                  icon: _connectionIcon(controller.status?.connection ?? 'offline'),
                ),
              const SizedBox(height: 13),
              Text(
                controller.status?.deviceName ?? 'This device',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                : _connectionLabel(controller.status?.connection ?? 'offline'),
            icon: controller.status?.paused == true
                ? Icons.pause_rounded
                : _connectionIcon(controller.status?.connection ?? 'offline'),
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
          child: Icon(Icons.copy_all_rounded, size: 19, color: theme.colorScheme.onPrimary),
        ),
        if (!compact) ...[
          const SizedBox(width: 11),
          Text('Arcade', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
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
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected ? theme.colorScheme.primary.withValues(alpha: 0.09) : Colors.transparent,
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
                        fontWeight: selected ? FontWeight.w650 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (trailing != null)
                    Text(trailing!, style: theme.textTheme.labelSmall?.copyWith(color: color)),
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
  const _StatusPill({required this.label, required this.icon, this.private = false});

  final String label;
  final IconData icon;
  final bool private;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: (private ? colors.tertiary : colors.primary).withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: private ? colors.tertiary : colors.primary),
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
  String? _qrImportError;

  @override
  void dispose() {
    _deviceName.dispose();
    _invite.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
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
          'Your clipboard,\nwhere you need it.',
          style: theme.textTheme.displaySmall?.copyWith(
            height: 1.08,
            letterSpacing: -1.2,
            fontWeight: FontWeight.w650,
          ),
        ),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            'Pair your own devices once. Clips you choose to share stay in your private mesh, ready when you need them.',
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
        Text('Get started', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w650)),
        const SizedBox(height: 7),
        Text(
          'No account needed. This name helps you recognize the device.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _deviceName,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Device name', hintText: 'e.g. Studio Mac'),
        ),
        if (controller.desktopAvailable) ...[
          const SizedBox(height: 16),
          _SettingLine(
            icon: Icons.content_paste_search_rounded,
            title: 'Automatically add desktop copies',
            description: 'Arcade reads copied text and cannot identify passwords or other sensitive clips. Use Private mode before copying anything you do not want shared.',
            trailing: Switch.adaptive(
              value: controller.automaticDesktopCapture,
              onChanged: controller.working ? null : controller.setAutomaticDesktopCapture,
            ),
          ),
        ],
        const SizedBox(height: 13),
        if (!_joining)
          FilledButton.icon(
            onPressed: controller.working ? null : () => controller.createMesh(_deviceName.text),
            icon: const Icon(Icons.add_link_rounded, size: 19),
            label: const Text('Create a device mesh'),
          )
        else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _importingQr ? null : _importQrImage,
              icon: _importingQr
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.qr_code_2_rounded, size: 18),
              label: Text(_importingQr ? 'Reading QR image…' : 'Import QR image'),
            ),
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
                : () => controller.joinMesh(invite: _invite.text, deviceName: _deviceName.text),
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
          onPressed: controller.working ? null : () => setState(() => _joining = !_joining),
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
          ),
        ],
      );
      if (file == null) return;
      if (file.size > InviteQrDecoder.maxFileBytes) {
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
  const _JoinVerificationCard({required this.controller, required this.pairing});

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
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
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
                fontWeight: FontWeight.w650,
                letterSpacing: 1.4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (pairing.expiresAt case final expiresAt?) ...[
            const SizedBox(height: 5),
            Text(
              'Expires ${_relativeExpiry(expiresAt)}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                      : () => controller.confirmPairing(pairing.sessionId, accept: true),
                  child: const Text('Approve'),
                ),
                TextButton(
                  onPressed: controller.working
                      ? null
                      : () => controller.confirmPairing(pairing.sessionId, accept: false),
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
              const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(height: 17),
              Text('Opening your private mesh', style: Theme.of(context).textTheme.bodyMedium),
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final items = controller.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PageTitle(
          eyebrow: 'YOUR MESH',
          title: 'Clipboard',
          trailing: controller.desktopCapabilities?.globalShortcut == true
              ? _KeyboardHint(shortcut: controller.shortcut)
              : null,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _search,
          onChanged: _onSearch,
          decoration: InputDecoration(
            hintText: 'Search your clips',
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: _search.text.isNotEmpty
                ? IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      _search.clear();
                      _onSearch('');
                    },
                    icon: const Icon(Icons.close_rounded, size: 19),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 14),
        if (controller.error != null) _InlineMessage(text: controller.error!, error: true),
        if (controller.notice != null) ...[
          const SizedBox(height: 8),
          _InlineMessage(text: controller.notice!),
        ],
        if (controller.status?.paused == true) ...[
          const SizedBox(height: 10),
          _NoticeStrip(
            icon: Icons.pause_circle_outline_rounded,
            text: 'Private mode is on. New clips are staying off your mesh.',
            actionLabel: 'Resume',
            onAction: () => controller.setPrivatePause(false),
          ),
        ],
        if (controller.status?.connection == 'offline' && !controller.devices.isEmpty) ...[
          const SizedBox(height: 10),
          _NoticeStrip(
            icon: Icons.cloud_off_rounded,
            text: 'Offline. New clips will sync when a connection returns.',
            actionLabel: 'Details',
            onAction: widget.onGoToDevices,
          ),
        ],
        const SizedBox(height: 20),
        if (controller.historyLoading && items.isEmpty)
          const Expanded(child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (items.isEmpty)
          Expanded(child: _ClipboardEmptyState(hasQuery: _search.text.trim().isNotEmpty))
        else
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: items.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: theme.dividerColor),
              itemBuilder: (context, index) => _ClipboardRow(
                item: items[index],
                onTap: () => controller.copyLocally(items[index]),
                onPin: () => controller.setPinned(items[index], !items[index].pinned),
                onDelete: () => controller.deleteItem(items[index]),
              ),
            ),
          ),
      ],
    );
  }

  void _onSearch(String value) {
    setState(() {});
    unawaited(widget.controller.refreshHistory(query: value));
  }
}

class _ClipboardRow extends StatelessWidget {
  const _ClipboardRow({
    required this.item,
    required this.onTap,
    required this.onPin,
    required this.onDelete,
  });

  final ClipboardItem item;
  final VoidCallback onTap;
  final VoidCallback onPin;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUrl = item.kind == 'url';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 15),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 35,
              height: 35,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                item.pinned ? Icons.push_pin_rounded : (isUrl ? Icons.link_rounded : Icons.notes_rounded),
                size: 17,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.preview.isEmpty ? 'Empty clip' : item.preview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        child: Text('·', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                      ),
                      Text(
                        _relativeTime(item.createdAt),
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Clip actions',
              icon: const Icon(Icons.more_horiz_rounded, size: 20),
              onSelected: (action) {
                if (action == 'pin') onPin();
                if (action == 'delete') onDelete();
                if (action == 'copy') onTap();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'copy', child: Text('Copy to this device')),
                PopupMenuItem(value: 'pin', child: Text(item.pinned ? 'Unpin clip' : 'Pin clip')),
                const PopupMenuItem(value: 'delete', child: Text('Delete clip')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ClipboardEmptyState extends StatelessWidget {
  const _ClipboardEmptyState({required this.hasQuery});

  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasQuery ? Icons.search_off_rounded : Icons.content_paste_rounded,
            size: 27,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            hasQuery ? 'No matching clips' : 'Your shared clipboard is empty',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          SizedBox(
            width: 300,
            child: Text(
              hasQuery
                  ? 'Try another word or source device.'
                  : 'Copy something on a desktop, or share text to Arcade Clipboard from your phone.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DevicesPage extends StatelessWidget {
  const _DevicesPage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PageTitle(
          eyebrow: 'YOUR MESH',
          title: 'Devices',
          trailing: controller.canManageDevices || controller.devicesLoading
              ? FilledButton.tonalIcon(
                  onPressed: controller.working || !controller.canManageDevices
                      ? null
                      : () => _addDevice(context),
                  icon: controller.devicesLoading && !controller.canManageDevices
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
            Text('${controller.devices.length}', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 9),
        if (controller.pairings.isNotEmpty) ...[
          for (final pairing in controller.pairings) ...[
            _PairingRequestTile(controller: controller, pairing: pairing),
            const SizedBox(height: 8),
          ],
        ],
        Expanded(
          child: controller.devicesLoading && controller.devices.isEmpty
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : controller.devices.isEmpty
                  ? _DevicesEmptyState(
                      onAdd: controller.canManageDevices ? () => _addDevice(context) : null,
                    )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: controller.devices.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: theme.dividerColor),
                  itemBuilder: (context, index) {
                    final device = controller.devices[index];
                    return _TrustedDeviceRow(
                      device: device,
                      onRemove: controller.canManageDevices && !device.isOwner
                          ? () => _confirmRemove(context, device)
                          : null,
                    );
                  },
                ),
        ),
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
      builder: (context) => _InviteDialog(invite: invite),
    );
  }

  Future<void> _confirmRemove(BuildContext context, MeshDevice device) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${device.name}?'),
        content: const Text('This device will lose access to future clips from your mesh.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton.tonal(onPressed: () => Navigator.pop(context, true), child: const Text('Remove device')),
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
                  : 'Your mesh is ready for another device.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (onAdd != null) ...[
              const SizedBox(height: 11),
              TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded), label: const Text('Add a device')),
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
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
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
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.35),
          ),
          if (pairing.verificationCode.isNotEmpty) ...[
            const SizedBox(height: 11),
            Text(
              pairing.verificationCode,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w650,
                letterSpacing: 1.4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (pairing.expiresAt case final expiresAt?) ...[
            const SizedBox(height: 5),
            Text(
              'Expires ${_relativeExpiry(expiresAt)}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          if (inbound && awaitingConfirmation) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: controller.working
                      ? null
                      : () => controller.confirmPairing(pairing.sessionId, accept: true),
                  child: const Text('Approve'),
                ),
                const SizedBox(width: 7),
                TextButton(
                  onPressed: controller.working
                      ? null
                      : () => controller.confirmPairing(pairing.sessionId, accept: false),
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
  const _DeviceRow({required this.name, required this.platform, required this.state, this.current = false});

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
                Text(name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(platform, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
                Text(device.name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  '${device.platform}${device.lastSeen == null ? '' : ' · seen ${_relativeTime(device.lastSeen!)}'}',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          _PresenceLabel(state: device.state),
          if (onRemove != null)
            PopupMenuButton<String>(
              tooltip: 'Device actions',
              onSelected: (_) => onRemove!(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Remove device'))],
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
    final icon = name.contains('ios') || name.contains('iphone') || name.contains('ipad')
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
    final online = current || state.toLowerCase() == 'online' || state.toLowerCase() == 'connected';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 7, color: online ? colors.primary : colors.outline),
        const SizedBox(width: 6),
        Text(
          current ? 'This device' : online ? 'Online' : 'Offline',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
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
        const _PageTitle(eyebrow: 'PREFERENCES', title: 'Settings'),
        const SizedBox(height: 28),
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
          description: 'Clips expire from this mesh after the selected time.',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _retentionValue(controller.retentionHours),
              items: const [
                DropdownMenuItem(value: 1, child: Text('1 hour')),
                DropdownMenuItem(value: 24, child: Text('24 hours')),
                DropdownMenuItem(value: 168, child: Text('7 days')),
                DropdownMenuItem(value: 720, child: Text('30 days')),
              ],
              onChanged: controller.working ? null : (value) {
                if (value != null) controller.setRetentionHours(value);
              },
            ),
          ),
        ),
        const SizedBox(height: 26),
        Text('DESKTOP', style: _eyebrowStyle(context)),
        const SizedBox(height: 8),
        if (controller.desktopAvailable)
          _SettingLine(
            icon: Icons.content_paste_search_rounded,
            title: 'Automatically add desktop copies',
            description: 'Arcade reads copied text and cannot identify passwords or other sensitive clips. Use Private mode before copying anything you do not want shared.',
            trailing: Switch.adaptive(
              value: controller.automaticDesktopCapture,
              onChanged: controller.working ? null : controller.setAutomaticDesktopCapture,
            ),
          ),
        if (controller.desktopCapabilities?.globalShortcut == true)
          _SettingLine(
            icon: Icons.keyboard_command_key_rounded,
            title: 'Mesh Clipboard Shortcut',
            description: 'Open the clip picker over your current app.',
            trailing: TextButton(
              onPressed: controller.working ? null : _beginShortcutCapture,
              child: Text(_recording ? 'Listening…' : (_shortcutDraft ?? controller.shortcut)),
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
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        const Divider(height: 1),
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
          icon: _connectionIcon(controller.status?.connection ?? 'offline'),
          title: _connectionLabel(controller.status?.connection ?? 'offline'),
          description: controller.status?.diagnostic.isNotEmpty == true
              ? controller.status!.diagnostic
              : 'Your clips are encrypted on this device before synchronization.',
          trailing: IconButton(
            tooltip: 'Refresh status',
            onPressed: controller.refreshAll,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
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

  int _retentionValue(int hours) => const {1, 24, 168, 720}.contains(hours) ? hours : 24;

  void _beginShortcutCapture() {
    setState(() {
      _recording = true;
      _shortcutDraft = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _shortcutFocus.requestFocus());
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
    widget.controller.configureShortcut(shortcut).then((_) {
      if (mounted) setState(() => _shortcutDraft = null);
    });
    return KeyEventResult.handled;
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
    if (label.length == 1 || RegExp(r'^F\d{1,2}$').hasMatch(label)) return label;
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          SizedBox(width: 32, child: Icon(icon, size: 19, color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(description, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 14),
          trailing,
        ],
      ),
    );
  }
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.invite});

  final PairingInvite invite;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    final expiresAt = widget.invite.expiresAt;
    if (expiresAt != null && expiresAt.isAfter(DateTime.now())) {
      _expiryTimer = Timer(expiresAt.difference(DateTime.now()), () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final invite = widget.invite;
    final code = invite.displayCode;
    final expired = invite.expiresAt case final expiresAt? ? !expiresAt.isAfter(DateTime.now()) : false;
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
                : 'On your other device, choose Join mesh and scan this code or paste the invite.'),
            const SizedBox(height: 19),
            Container(
              width: 224,
              height: 224,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
              child: QrImageView(
                data: invite.invite,
                version: QrVersions.auto,
                gapless: false,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
            const SizedBox(height: 13),
            Text(
              invite.expiresAt == null ? 'This invite expires soon.' : 'Expires ${_relativeExpiry(invite.expiresAt!)}',
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 13),
            SelectableText(
              code,
              maxLines: 3,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: expired ? null : () => Clipboard.setData(ClipboardData(text: invite.invite)),
          child: const Text('Copy invite'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
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
          duration: const Duration(milliseconds: 110),
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
                      child: Text('Mesh Clipboard', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w650)),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: widget.controller.dismissOverlay,
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                TextField(
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
                ),
                if (widget.controller.overlaySearchLoading)
                  const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: 10),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Text(
                            _search.text.isEmpty ? 'Your shared clipboard is empty.' : 'No matching clips.',
                            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemExtent: 82,
                          itemCount: items.length,
                          itemBuilder: (context, index) => _OverlayClipRow(
                            item: items[index],
                            selected: index == selectedIndex,
                            onTap: () => widget.controller.selectOverlayItem(items[index]),
                            onHover: (_) => setState(() => _selectedItemId = items[index].id),
                          ),
                        ),
                ),
                Divider(height: 1, color: theme.dividerColor),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const _KeyCap('↑'),
                    const SizedBox(width: 4),
                    const _KeyCap('↓'),
                    const SizedBox(width: 8),
                    Text('Navigate', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const Spacer(),
                    const _KeyCap('Enter'),
                    const SizedBox(width: 6),
                    Text('Paste', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(width: 13),
                    const _KeyCap('Esc'),
                    const SizedBox(width: 6),
                    Text('Close', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final items = _visible;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.controller.dismissOverlay();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && items.isNotEmpty) {
      final next = (_selectedIndex(items) + 1) % items.length;
      setState(() => _selectedItemId = items[next].id);
      _revealSelection(next);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && items.isNotEmpty) {
      final previous = (_selectedIndex(items) - 1 + items.length) % items.length;
      setState(() => _selectedItemId = items[previous].id);
      _revealSelection(previous);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && items.isNotEmpty) {
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
          color: selected ? theme.colorScheme.primary.withValues(alpha: 0.10) : Colors.transparent,
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
                    item.kind == 'url' ? Icons.link_rounded : Icons.notes_rounded,
                    size: 18,
                    color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(height: 1.35)),
                        const SizedBox(height: 5),
                        Text(
                          '${item.sourceName}  ·  ${_relativeTime(item.createdAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
              Text(eyebrow, style: _eyebrowStyle(context)),
              const SizedBox(height: 5),
              Text(title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w650, letterSpacing: -0.5)),
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
        Text('Open mesh clipboard', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
      child: Text(label, style: theme.textTheme.labelSmall?.copyWith(fontSize: 10)),
    );
  }
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({required this.text, this.error = false});

  final String text;
  final bool error;

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
          Icon(error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              size: 17, color: error ? colors.error : colors.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4))),
        ],
      ),
    );
  }
}

class _NoticeStrip extends StatelessWidget {
  const _NoticeStrip({required this.icon, required this.text, required this.actionLabel, required this.onAction});

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

TextStyle? _eyebrowStyle(BuildContext context) => Theme.of(context).textTheme.labelSmall?.copyWith(
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

IconData _connectionIcon(String value) {
  final normalized = value.toLowerCase();
  if (normalized.contains('online') || normalized.contains('connected')) return Icons.cloud_done_rounded;
  if (normalized.contains('connect')) return Icons.sync_rounded;
  return Icons.cloud_off_rounded;
}

String _connectionLabel(String value) {
  final normalized = value.toLowerCase();
  if (normalized.contains('online') || normalized.contains('connected')) return 'Connected';
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
