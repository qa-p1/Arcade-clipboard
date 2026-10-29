part of 'app.dart';

enum _Section { history, devices, settings }

/// Template A (STANDARD §6): the kit sidebar beside the page on desktop,
/// collapsing to icons below 760 px, and a bottom navigation bar on phones.
class _AppHome extends StatefulWidget {
  const _AppHome({required this.controller});

  final AppController controller;

  @override
  State<_AppHome> createState() => _AppHomeState();
}

class _AppHomeState extends State<_AppHome> {
  _Section _section = _Section.history;

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

  void _select(_Section section) => setState(() => _section = section);

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.loading) return const _LoadingView();
    if (!controller.hasMesh) return _WelcomeView(controller: controller);

    return LayoutBuilder(builder: (context, constraints) {
      final phone = constraints.maxWidth < 600;
      final page = switch (_section) {
        _Section.history => _ClipboardPage(
            controller: controller,
            onGoToDevices: () => _select(_Section.devices)),
        _Section.devices => _DevicesPage(controller: controller),
        _Section.settings => _SettingsPage(controller: controller),
      };
      final shortcuts = <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            _openSettings,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            _openSettings,
      };
      if (phone) {
        final c = arcadeColors(context);
        return CallbackShortcuts(
          bindings: shortcuts,
          child: Scaffold(
            body: SafeArea(child: page),
            bottomNavigationBar: NavigationBar(
              height: 64,
              backgroundColor: c.bg,
              indicatorColor: c.accentSoft,
              selectedIndex: _section.index,
              onDestinationSelected: (index) => _select(_Section.values[index]),
              destinations: [
                const NavigationDestination(
                    icon: ArcadeIcon('clipboard', size: 20), label: 'History'),
                NavigationDestination(
                  icon: controller.pairings.isEmpty
                      ? const ArcadeIcon('monitor', size: 20)
                      : Badge(
                          label: Text('${controller.pairings.length}'),
                          child: const ArcadeIcon('monitor', size: 20)),
                  label: 'Devices',
                ),
                const NavigationDestination(
                    icon: ArcadeIcon('settings', size: 20), label: 'Settings'),
              ],
            ),
          ),
        );
      }
      final collapsed = constraints.maxWidth < ArcadeTokens.collapseBelow;
      return CallbackShortcuts(
        bindings: shortcuts,
        child: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Sidebar(
                  controller: controller,
                  selected: _section,
                  onSelected: _select,
                  collapsed: collapsed),
              Expanded(child: SafeArea(child: page)),
            ],
          ),
        ),
      );
    });
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar(
      {required this.controller,
      required this.selected,
      required this.onSelected,
      required this.collapsed});

  final AppController controller;
  final _Section selected;
  final ValueChanged<_Section> onSelected;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = _syncState(controller);
    final c = arcadeColors(context);
    return SafeArea(
      child: ArcadeSidebar(
        appName: 'Arcade Clipboard',
        mark: const ArcadeIcon('clipboard'),
        collapsed: collapsed,
        version: controller.appVersion,
        footer: collapsed
            ? Tooltip(
                message: label, child: Center(child: ArcadeDot(tone: tone)))
            : Row(children: [
                ArcadeDot(tone: tone),
                const SizedBox(width: ArcadeTokens.space8),
                Expanded(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: ArcadeTokens.textSmall.copyWith(color: c.muted)),
                ),
              ]),
        items: [
          ArcadeNavItem(
            icon: 'clipboard',
            label: 'History',
            collapsed: collapsed,
            selected: selected == _Section.history,
            onTap: () => onSelected(_Section.history),
          ),
          ArcadeNavItem(
            icon: 'monitor',
            label: 'Devices',
            collapsed: collapsed,
            count: controller.pairings.isNotEmpty
                ? controller.pairings.length
                : null,
            selected: selected == _Section.devices,
            onTap: () => onSelected(_Section.devices),
          ),
          ArcadeNavItem(
            icon: 'settings',
            label: 'Settings',
            collapsed: collapsed,
            selected: selected == _Section.settings,
            onTap: () => onSelected(_Section.settings),
          ),
        ],
      ),
    );
  }
}

/// A page's scrolling column: max 980 px, centred, padding 32/36/72.
class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 600;
    return SingleChildScrollView(
      padding: phone
          ? const EdgeInsets.fromLTRB(ArcadeTokens.space16,
              ArcadeTokens.space20, ArcadeTokens.space16, ArcadeTokens.space32)
          : const EdgeInsets.fromLTRB(36, ArcadeTokens.space32, 36, 72),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ArcadeTokens.contentMax),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children),
        ),
      ),
    );
  }
}

/// The space between sections (STANDARD §6).
const Widget _sectionGap = SizedBox(height: ArcadeTokens.space32);

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(height: ArcadeTokens.space16),
              Text('Opening Arcade Clipboard…',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      );
}

/// The controller's error and notice as kit notices.
class _Messages extends StatelessWidget {
  const _Messages({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (controller.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: ArcadeTokens.space12),
            child: ArcadeNotice(controller.error!, tone: ArcadeTone.danger),
          ),
        if (controller.notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: ArcadeTokens.space12),
            child: ArcadeNotice(
              controller.notice!,
              tone: ArcadeTone.ok,
              action: ArcadeButton(
                  label: 'Dismiss',
                  icon: 'x',
                  iconOnly: true,
                  small: true,
                  variant: ArcadeButtonVariant.ghost,
                  onPressed: controller.dismissNotice),
            ),
          ),
      ]);
}

/// Ticks every 30 s while a relative time ("2 min ago") is on screen and the
/// app is in the foreground, so those labels keep up without waking a hidden app.
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

/// "Just now", "5 min ago", "Yesterday 14:05" (the kit's wording).
String _relativeTime(DateTime time) =>
    formatRelative(time.millisecondsSinceEpoch);

/// "in 5 min", "in 2 h" for invites and pairing requests.
String _relativeExpiry(DateTime time) {
  final remaining = time.difference(DateTime.now()).inSeconds;
  if (remaining <= 0) return 'now';
  return 'in ${formatDuration(remaining.toDouble(), DurationStyle.job)}';
}

/// The sync status shown in the sidebar footer and on the devices page.
(String, ArcadeTone) _syncState(AppController controller) {
  if (controller.status?.paused == true) {
    return ('Private mode', ArcadeTone.warn);
  }
  if (controller.hasMesh && controller.devices.isEmpty) {
    return ('Ready', ArcadeTone.ok);
  }
  final connection = (controller.status?.connection ?? 'offline').toLowerCase();
  if (connection == 'online' ||
      connection == 'connected' ||
      connection == 'lan' ||
      connection == 'relay') {
    return switch (controller.status?.transport) {
      'lan' => ('Synced on the local network', ArcadeTone.ok),
      'relay' => ('Synced through the relay', ArcadeTone.ok),
      _ => ('Synced', ArcadeTone.ok),
    };
  }
  if (connection.contains('connect')) return ('Connecting…', ArcadeTone.warn);
  return ('Offline', ArcadeTone.neutral);
}

String _platformLabel() => switch (Platform.operatingSystem) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      'ios' => 'iOS',
      'android' => 'Android',
      _ => 'This device',
    };
