part of '../app.dart';

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
              value: controller.retentionHours > 0
                  ? controller.retentionHours
                  : 24,
              items: [
                for (final hours in _withCurrent(
                    const [1, 24, 168, 720], controller.retentionHours))
                  DropdownMenuItem(
                      value: hours, child: Text(_retentionLabel(hours))),
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
            value: controller.maxItems > 0 ? controller.maxItems : 500,
            items: [
              for (final count
                  in _withCurrent(const [500, 1000, 5000], controller.maxItems))
                DropdownMenuItem(
                    value: count, child: Text('${_grouped(count)} clips')),
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
              title: 'Picker shortcut',
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
              title: 'Picker shortcut',
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

  /// The presets, plus the current value when it came from elsewhere (an
  /// imported settings file, Arcade Tools) so Settings shows what applies.
  static List<int> _withCurrent(List<int> presets, int current) =>
      presets.contains(current) || current <= 0
          ? presets
          : ([...presets, current]..sort());

  static String _retentionLabel(int hours) {
    if (hours % 24 == 0 && hours >= 48) return '${hours ~/ 24} days';
    return hours == 1 ? '1 hour' : '$hours hours';
  }

  static String _grouped(int value) => value.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'), (match) => '${match[1]},');

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
