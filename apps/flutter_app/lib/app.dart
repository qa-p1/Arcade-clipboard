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

part 'dialogs/invite_dialog.dart';
part 'overlay/quick_overlay.dart';
part 'pages/devices.dart';
part 'pages/history.dart';
part 'pages/settings.dart';
part 'pages/welcome.dart';

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
  void initState() {
    super.initState();
    widget.controller.settingsRequests.addListener(_openSettings);
  }

  @override
  void dispose() {
    widget.controller.settingsRequests.removeListener(_openSettings);
    super.dispose();
  }

  void _openSettings() => _select(_Section.settings);

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

/// Ticks every 30 s while a relative time ("2m ago") is on screen and the app
/// is in the foreground, so those labels keep up without waking a hidden app.
class _RelativeClock extends ChangeNotifier with WidgetsBindingObserver {
  _RelativeClock._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final instance = _RelativeClock._();
  Timer? _timer;

  void _update() {
    final state = WidgetsBinding.instance.lifecycleState;
    final run = hasListeners &&
        (state == null ||
            state == AppLifecycleState.resumed ||
            state == AppLifecycleState.inactive);
    if (run) {
      _timer ??=
          Timer.periodic(const Duration(seconds: 30), (_) => notifyListeners());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _update();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back after a while: show the current ages at once.
    if (state == AppLifecycleState.resumed) notifyListeners();
    _update();
  }
}

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
