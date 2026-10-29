part of '../app.dart';

/// Settings in the standard order (STANDARD §6): General, Shortcuts, then
/// Clipboard's own Privacy and Sync, Connected apps and About.
class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.controller});

  final AppController controller;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late final TextEditingController _relay =
      TextEditingController(text: widget.controller.relayUrl);
  final FocusNode _relayFocus = FocusNode();
  String? _relayError;
  Future<AboutInfo>? _about;

  @override
  void initState() {
    super.initState();
    _relayFocus.addListener(() {
      if (!_relayFocus.hasFocus) _applyRelay();
    });
    _about = widget.controller.loadAbout();
  }

  @override
  void dispose() {
    _relay.dispose();
    _relayFocus.dispose();
    super.dispose();
  }

  /// Applies the relay address on Enter or when the field loses focus, with
  /// inline validation instead of a Save button.
  Future<void> _applyRelay() async {
    final value = _relay.text.trim();
    if (value == widget.controller.relayUrl) {
      setState(() => _relayError = null);
      return;
    }
    final uri = Uri.tryParse(value);
    if (value.isNotEmpty &&
        (uri == null ||
            !(uri.scheme == 'wss' || uri.scheme == 'ws') ||
            uri.host.isEmpty)) {
      setState(() => _relayError =
          'Enter a relay address such as wss://relay.example.com, or leave it empty.');
      return;
    }
    setState(() => _relayError = null);
    await widget.controller.setRelayUrl(value);
  }

  Future<void> _clearHistory() async {
    final confirmed = await confirmArcadeDestroy(
      context,
      title: 'Clear unpinned history?',
      message:
          'Unpinned clips are deleted here and on your paired devices when they reconnect. Pinned clips stay.',
      confirmLabel: 'Clear history',
    );
    if (confirmed) await widget.controller.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final c = arcadeColors(context);
    final desktop = controller.desktopAvailable;
    final working = controller.working;
    return _PageFrame(children: [
      const ArcadePageHead(title: 'Settings'),
      _Messages(controller: controller),

      // 1. General
      ArcadeListSection(title: 'General', children: [
        ArcadeRow(
          title: 'Appearance',
          trailing: ArcadeSegmented<ThemeMode>(
            options: const [
              (ThemeMode.system, 'System'),
              (ThemeMode.light, 'Light'),
              (ThemeMode.dark, 'Dark')
            ],
            value: controller.themeMode,
            onChanged: controller.setThemeMode,
          ),
        ),
        if (desktop) ...[
          ArcadeSwitchRow(
            title: 'Start at login',
            subtitle: 'Starts in the background when you sign in.',
            value: controller.launchAtLogin,
            onChanged: working ? null : controller.setLaunchAtLogin,
          ),
          ArcadeSwitchRow(
            title: 'Keep running when the window is closed',
            subtitle:
                'Your devices stay in sync. Open Arcade Clipboard again from the tray.',
            value: controller.backgroundEnabled,
            onChanged: working ? null : controller.setBackgroundEnabled,
          ),
          if (Platform.isMacOS &&
              controller.desktopCapabilities?.paste == false)
            ArcadeRow(
              title: 'Paste into other apps',
              subtitle:
                  'macOS needs Accessibility access to paste into the app you were using.',
              trailing: ArcadeButton(
                  label: 'Allow access',
                  small: true,
                  onPressed: controller.requestPasteAccess),
            ),
        ],
      ]),
      _sectionGap,

      // 2. Shortcuts
      ArcadeListSection(title: 'Shortcuts', children: [
        if (desktop && controller.desktopCapabilities?.globalShortcut == true)
          ArcadeRow(
            title: 'Open the quick picker',
            subtitle: 'Shows your clips over the app you are using.',
            extra: _ShortcutRecorder(controller: controller),
          )
        else if (desktop)
          const ArcadeRow(
            title: 'Open the quick picker',
            subtitle:
                'This desktop doesn’t let apps register a global shortcut. Bind `arcade-clipboard --overlay` in your desktop’s keyboard settings.',
          )
        else
          ArcadeRow(
            title: 'Clipboard keyboard',
            subtitle: Platform.isIOS
                ? 'Turn on Arcade Clipboard in Settings › General › Keyboard › Keyboards, then switch to it with the globe key to insert shared text.'
                : 'Turn on Arcade Clipboard in your keyboard settings, then switch to it to insert shared text.',
            trailing: ArcadeButton(
                label: 'Keyboard settings',
                small: true,
                onPressed: controller.openKeyboardSettings),
          ),
        if (desktop)
          ArcadeRow(
            title: 'In the quick picker',
            extra: Wrap(
                spacing: ArcadeTokens.space16,
                runSpacing: ArcadeTokens.space8,
                children: [
                  for (final (keys, label) in <(List<String>, String)>[
                    (['↑', '↓'], 'Move'),
                    (['↵'], 'Paste'),
                    (
                      [Platform.isMacOS ? '⌘' : 'Ctrl', '↵'],
                      'Paste as plain text'
                    ),
                    (['Esc'], 'Close'),
                  ])
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      ArcadeKeyCombo(keys),
                      const SizedBox(width: ArcadeTokens.space6),
                      Flexible(
                          child: Text(label,
                              style: ArcadeTokens.textSmall
                                  .copyWith(color: c.muted))),
                    ]),
                ]),
          ),
      ]),
      _sectionGap,

      // 3. Privacy
      ArcadeListSection(title: 'Privacy', children: [
        ArcadeSwitchRow(
          title: 'Private mode',
          subtitle:
              'Stops new clips from entering your mesh until you turn it off.',
          value: controller.status?.paused ?? false,
          onChanged: working ? null : controller.setPrivatePause,
        ),
        if (desktop)
          ArcadeSwitchRow(
            title: 'Add what you copy on this computer',
            subtitle:
                'Text, images and files you copy are added and synced. Use Private mode for anything you don’t want shared.',
            value: controller.automaticDesktopCapture,
            onChanged: working ? null : controller.setAutomaticDesktopCapture,
          )
        else
          const ArcadeRow(
            title: 'Share to your devices',
            subtitle:
                'In another app, open Share and choose Arcade Clipboard. Open Arcade Clipboard to sync items waiting in your inbox.',
          ),
        ArcadeRow(
          title: 'Keep history',
          subtitle:
              'Unpinned clips are deleted after this time. Pinned clips stay until you unpin or delete them.',
          trailing: _Choice<int>(
            value:
                controller.retentionHours > 0 ? controller.retentionHours : 24,
            options: [
              for (final hours in _withCurrent(
                  const [1, 24, 168, 720], controller.retentionHours))
                (hours, _retentionLabel(hours))
            ],
            onChanged: working ? null : controller.setRetentionHours,
          ),
        ),
        ArcadeRow(
          title: 'History limit',
          subtitle:
              'The oldest clips are deleted when the limit is reached. Pinned clips are kept first.',
          trailing: _Choice<int>(
            value: controller.maxItems > 0 ? controller.maxItems : 500,
            options: [
              for (final count
                  in _withCurrent(const [500, 1000, 5000], controller.maxItems))
                (count, '${formatCount(count)} clips')
            ],
            onChanged: working ? null : controller.setMaxItems,
          ),
        ),
        ArcadeRow(
          title: 'Clear unpinned history',
          subtitle: 'Deletes unpinned clips here and on your paired devices.',
          trailing: ArcadeButton(
              label: 'Clear unpinned history…',
              small: true,
              variant: ArcadeButtonVariant.danger,
              onPressed: working ? null : _clearHistory),
        ),
      ]),
      _sectionGap,

      // 4. Sync
      Builder(builder: (context) {
        final (label, tone) = _syncState(controller);
        return ArcadeListSection(title: 'Sync', children: [
          ArcadeRow(
            title: 'Status',
            subtitle: controller.status?.diagnostic.isNotEmpty == true
                ? controller.status!.diagnostic
                : 'Clips are encrypted on this device before they sync.',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              ArcadeBadge(label, tone: tone, dot: tone == ArcadeTone.ok),
              const SizedBox(width: ArcadeTokens.space4),
              ArcadeButton(
                  label: 'Check again',
                  icon: 'refresh',
                  iconOnly: true,
                  small: true,
                  variant: ArcadeButtonVariant.ghost,
                  onPressed: controller.refreshAll),
            ]),
          ),
          ArcadeRow(
            title: 'Remote relay',
            subtitle:
                'Connects devices on different networks. Clips stay end-to-end encrypted. Leave it empty to sync on your local network only.',
            extra: TextField(
              controller: _relay,
              focusNode: _relayFocus,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onSubmitted: (_) => _applyRelay(),
              style: ArcadeTokens.textBody.copyWith(color: c.text),
              decoration: InputDecoration(
                  hintText: 'wss://relay.example.com',
                  errorText: _relayError,
                  errorMaxLines: 2),
            ),
          ),
        ]);
      }),
      if (desktop) ...[
        _sectionGap,
        // 5. Connected apps
        ConnectedAppsSection(controller: controller),
      ],
      _sectionGap,

      // 6. About
      FutureBuilder<AboutInfo>(
        future: _about,
        builder: (context, snapshot) {
          final about = snapshot.data;
          final version = about?.version.isNotEmpty == true
              ? about!.version
              : controller.appVersion ?? '';
          return ArcadeListSection(title: 'About', children: [
            ArcadeRow(
              title: 'Arcade Clipboard',
              subtitle: version.isEmpty
                  ? null
                  : 'Version $version · ${about?.channel ?? 'stable'}',
              leading: ArcadeGlyphTile(
                  color: c.accent,
                  child: ArcadeIcon('clipboard', color: c.accentText)),
            ),
            if (desktop)
              ArcadeRow(
                title: about?.toolsInstalled == true
                    ? 'Updates are managed by Arcade Tools'
                    : 'Updates',
                subtitle: about?.toolsInstalled == true
                    ? 'Arcade Tools installs new versions of Arcade Clipboard.'
                    : 'Install Arcade Tools to keep Arcade Clipboard up to date, or download new versions from the releases page.',
                trailing: about?.toolsInstalled == true
                    ? null
                    : ArcadeButton(
                        label: 'Releases',
                        icon: 'external',
                        small: true,
                        onPressed: () => controller.openUrl(
                            'https://github.com/qa-p1/Arcade-clipboard/releases')),
              ),
            ArcadeRow(
              title: 'User guide',
              trailing: ArcadeButton(
                  label: 'Open user guide',
                  icon: 'book',
                  small: true,
                  onPressed: controller.openUserGuide),
            ),
            if (desktop)
              ArcadeRow(
                title: 'Logs',
                subtitle: controller.logsFolder,
                trailing: ArcadeButton(
                    label: 'Open logs folder',
                    icon: 'folder',
                    small: true,
                    onPressed: controller.openLogsFolder),
              ),
            ArcadeRow(
              title: 'Diagnostics',
              subtitle:
                  'Version, platform and connection details for a bug report. Never your clips or keys.',
              trailing: ArcadeButton(
                  label: 'Copy diagnostics',
                  icon: 'copy',
                  small: true,
                  onPressed: controller.copyDiagnostics),
            ),
            ArcadeRow(
              title: 'Licences',
              trailing: ArcadeButton(
                label: 'View licences',
                small: true,
                onPressed: () => showLicensePage(
                    context: context,
                    applicationName: 'Arcade Clipboard',
                    applicationVersion: version),
              ),
            ),
          ]);
        },
      ),
    ]);
  }

  /// The presets, plus the current value when it came from elsewhere (an
  /// imported settings file, Arcade Tools) so Settings shows what applies.
  static List<int> _withCurrent(List<int> presets, int current) =>
      presets.contains(current) || current <= 0
          ? presets
          : ([...presets, current]..sort());

  static String _retentionLabel(int hours) => switch (hours) {
        1 => '1 hour',
        24 => '1 day',
        168 => '7 days',
        720 => '30 days',
        _ => formatDuration(hours * 3600.0, DurationStyle.job),
      };
}

/// A compact select for a settings row (more than four options).
class _Choice<T> extends StatelessWidget {
  const _Choice(
      {required this.value, required this.options, required this.onChanged});

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Container(
      height: ArcadeTokens.controlSm,
      padding: const EdgeInsets.only(
          left: ArcadeTokens.space10, right: ArcadeTokens.space4),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius:
            const BorderRadius.all(Radius.circular(ArcadeTokens.radiusSm)),
        border: Border.all(color: c.lineStrong),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          style: ArcadeTokens.textControl.copyWith(color: c.text),
          icon: ArcadeIcon('chevronDown', color: c.muted),
          borderRadius:
              const BorderRadius.all(Radius.circular(ArcadeTokens.radiusMd)),
          dropdownColor: c.panel,
          items: [
            for (final (option, label) in options)
              DropdownMenuItem(value: option, child: Text(label))
          ],
          onChanged: onChanged == null
              ? null
              : (selected) {
                  if (selected != null) onChanged!(selected);
                },
        ),
      ),
    );
  }
}

/// The shortcut recorder (STANDARD §5.1): the combo as key chips; click or
/// Enter records ("Press keys…"), Esc cancels; a modifier is required except
/// for F1–F24; a conflict shows "Used by …" with "Use anyway" / "Choose
/// another"; a valid combo applies at once; "Reset to default" beside it.
class _ShortcutRecorder extends StatefulWidget {
  const _ShortcutRecorder({required this.controller});

  final AppController controller;

  @override
  State<_ShortcutRecorder> createState() => _ShortcutRecorderState();
}

class _ShortcutRecorderState extends State<_ShortcutRecorder> {
  final FocusNode _focus = FocusNode();
  bool _recording = false;
  String? _draft;
  String? _conflict;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    setState(() {
      _recording = true;
      _draft = null;
      _conflict = null;
    });
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_recording) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space)) {
        _start();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _recording = false);
      return KeyEventResult.handled;
    }
    if (_isModifier(event.logicalKey)) return KeyEventResult.handled;
    final key = _keyName(event.logicalKey);
    if (key.isEmpty) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final parts = <String>[
      if (Platform.isMacOS && keyboard.isMetaPressed) 'CMD',
      if (keyboard.isControlPressed) 'CTRL',
      if (keyboard.isAltPressed) 'ALT',
      if (keyboard.isShiftPressed) 'SHIFT',
    ];
    final function = RegExp(r'^F\d{1,2}$').hasMatch(key);
    if (parts.isEmpty && !function) return KeyEventResult.handled;
    final shortcut = [...parts, key].join('+');
    final owner = widget.controller.link.shortcutOwner(shortcut);
    setState(() {
      _recording = false;
      _draft = shortcut;
      _conflict = owner == null ? null : 'Used by $owner';
    });
    if (owner == null) _save(shortcut);
    return KeyEventResult.handled;
  }

  void _save(String shortcut) {
    setState(() => _conflict = null);
    widget.controller.configureShortcut(shortcut).then((_) {
      if (mounted) setState(() => _draft = null);
    });
  }

  static final _modifiers = <LogicalKeyboardKey>{
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  static bool _isModifier(LogicalKeyboardKey key) => _modifiers.contains(key);

  static String _keyName(LogicalKeyboardKey key) {
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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final c = arcadeColors(context);
    final current = _draft ?? controller.shortcut;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(
          spacing: ArcadeTokens.space8,
          runSpacing: ArcadeTokens.space8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Focus(
              focusNode: _focus,
              onKeyEvent: _onKey,
              onFocusChange: (focused) {
                if (!focused && _recording) setState(() => _recording = false);
              },
              child: Semantics(
                button: true,
                label: _recording
                    ? 'Recording a shortcut. Press keys, or Esc to cancel.'
                    : 'Shortcut ${_shortcutKeys(current).join(' ')}. Press Enter to change it.',
                child: InkWell(
                  onTap: controller.working ? null : _start,
                  borderRadius: const BorderRadius.all(
                      Radius.circular(ArcadeTokens.radiusSm)),
                  child: AnimatedContainer(
                    duration: ArcadeTokens.fast,
                    constraints: const BoxConstraints(
                        minHeight: ArcadeTokens.control, minWidth: 140),
                    padding: const EdgeInsets.symmetric(
                        horizontal: ArcadeTokens.space8,
                        vertical: ArcadeTokens.space4),
                    decoration: BoxDecoration(
                      color: c.panel,
                      borderRadius: const BorderRadius.all(
                          Radius.circular(ArcadeTokens.radiusSm)),
                      border: Border.all(
                          color: _recording ? c.accent : c.lineStrong,
                          width: _recording ? 2 : 1),
                    ),
                    child: _recording
                        ? Text('Press keys…',
                            style: ArcadeTokens.textControl
                                .copyWith(color: c.accentInk))
                        : ExcludeSemantics(
                            child: ArcadeKeyCombo(_shortcutKeys(current))),
                  ),
                ),
              ),
            ),
            if (controller.shortcut != DesktopAdapter.defaultShortcut)
              ArcadeButton(
                label: 'Reset to default',
                small: true,
                variant: ArcadeButtonVariant.ghost,
                onPressed: controller.working
                    ? null
                    : () => _save(DesktopAdapter.defaultShortcut),
              ),
          ]),
      if (_conflict != null) ...[
        const SizedBox(height: ArcadeTokens.space8),
        ArcadeNotice(
          _conflict!,
          tone: ArcadeTone.warn,
          action: Wrap(spacing: ArcadeTokens.space8, children: [
            ArcadeButton(
                label: 'Choose another', small: true, onPressed: _start),
            ArcadeButton(
                label: 'Use anyway',
                small: true,
                onPressed: () => _save(_draft!)),
          ]),
        ),
      ],
    ]);
  }
}
