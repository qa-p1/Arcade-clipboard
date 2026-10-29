part of '../app.dart';

/// History filters: the segmented control's options (STANDARD §5.1).
enum _ClipFilter { all, text, images, links, files, pinned }

bool _matches(_ClipFilter filter, ClipboardItem item) => switch (filter) {
      _ClipFilter.all => true,
      _ClipFilter.text => item.kind == 'text' || item.kind == 'rich_text' || item.kind == 'html',
      _ClipFilter.images => item.kind == 'image',
      _ClipFilter.links => item.kind == 'url',
      _ClipFilter.files => item.kind == 'file' || item.kind == 'files',
      _ClipFilter.pinned => item.pinned,
    };

class _ClipboardPage extends StatefulWidget {
  const _ClipboardPage({required this.controller, required this.onGoToDevices});

  final AppController controller;
  final VoidCallback onGoToDevices;

  @override
  State<_ClipboardPage> createState() => _ClipboardPageState();
}

class _ClipboardPageState extends State<_ClipboardPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _searchTimer;
  _ClipFilter _filter = _ClipFilter.all;
  String _source = '';

  @override
  void initState() {
    super.initState();
    _search.text = widget.controller.query ?? '';
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _clearFilters() {
    _search.clear();
    _onSearch('');
    setState(() {
      _filter = _ClipFilter.all;
      _source = '';
    });
  }

  Future<void> _clearHistory() async {
    final confirmed = await confirmArcadeDestroy(
      context,
      title: 'Clear history?',
      message: 'Unpinned clips are deleted here and on your paired devices when they reconnect. Pinned clips stay.',
      confirmLabel: 'Clear history',
    );
    if (confirmed) await widget.controller.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final c = arcadeColors(context);
    final allItems = controller.items;
    final items = allItems.where((item) => _matches(_filter, item) && (_source.isEmpty || item.originDevice == _source)).toList();
    final filtered = _search.text.trim().isNotEmpty || _filter != _ClipFilter.all || _source.isNotEmpty;
    final sources = <String, String>{
      if (controller.status?.deviceId != null) controller.status!.deviceId!: 'This device',
      for (final device in controller.devices) device.id: device.name,
      for (final item in allItems) item.originDevice: item.sourceName,
    };
    final paused = controller.status?.paused == true;
    final deviceCount = controller.devices.length;
    final subtitle = '${formatCount(allItems.length)} ${allItems.length == 1 ? 'clip' : 'clips'} · '
        '${deviceCount == 0 ? 'not synced with other devices yet' : 'synced with $deviceCount ${deviceCount == 1 ? 'device' : 'devices'}'}';

    final Widget list;
    if (items.isEmpty && controller.historyLoading) {
      list = ArcadeListSection(children: [for (var i = 0; i < 4; i++) const ArcadeSkeletonRow()]);
    } else if (items.isEmpty && controller.error != null && allItems.isEmpty) {
      list = ArcadeNotice("Couldn't load your clips. ${controller.error}",
          tone: ArcadeTone.danger,
          action: ArcadeButton(label: 'Retry', small: true, onPressed: () => controller.refreshHistory(query: _search.text)));
    } else if (items.isEmpty) {
      list = filtered
          ? ArcadeEmptyState(
              icon: 'search',
              title: _search.text.trim().isEmpty ? 'No matching clips' : 'No clips match “${_search.text.trim()}”',
              message: 'Try another search or clear the filters.',
              actions: [ArcadeButton(label: 'Clear filters', onPressed: _clearFilters)],
            )
          : ArcadeEmptyState(
              icon: 'clipboard',
              title: 'Copy something and it shows up here',
              message: controller.automaticDesktopCapture
                  ? 'Text, images, links and files you copy are kept and synced to your devices.'
                  : 'Add a clip here, or share one to Arcade Clipboard from your phone.',
              actions: [
                ArcadeButton(label: 'Add clip', icon: 'plus', onPressed: paused ? null : () => showAddClip(context, controller)),
              ],
            );
    } else {
      list = ArcadeListSection(children: [
        for (final item in items)
          _ClipboardRow(
            controller: controller,
            item: item,
            onTap: () => showClipDetail(context, controller, item),
            onCopy: () => controller.copyLocally(item),
            onPin: () => controller.setPinned(item, !item.pinned),
            onDelete: () => controller.deleteItem(item),
            onResend: () => controller.resendItem(item),
          ),
      ]);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _searchFocus.requestFocus,
      },
      child: _PageFrame(children: [
        ArcadePageHead(title: 'History', subtitle: subtitle, actions: [
          ArcadeButton(
            label: 'Add clip',
            icon: 'plus',
            onPressed: controller.working || paused ? null : () => showAddClip(context, controller),
          ),
          ArcadeButton(
            label: 'Clear history…',
            variant: ArcadeButtonVariant.danger,
            onPressed: controller.working || allItems.isEmpty ? null : _clearHistory,
          ),
        ]),
        _Messages(controller: controller),
        WaitingPhoto(controller: controller),
        LinkWorkStatus(controller: controller),
        if (paused)
          Padding(
            padding: const EdgeInsets.only(bottom: ArcadeTokens.space12),
            child: ArcadeNotice('Sharing is paused. Existing clips are still available.',
                tone: ArcadeTone.warn,
                title: 'Private mode',
                action: ArcadeButton(label: 'Resume', small: true, onPressed: () => controller.setPrivatePause(false))),
          ),
        if (controller.status?.connection == 'offline' && controller.devices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: ArcadeTokens.space12),
            child: ArcadeNotice('Offline. Clips sync when your devices reconnect.',
                action: ArcadeButton(label: 'Devices', small: true, onPressed: widget.onGoToDevices)),
          ),
        ArcadeSearchField(
          controller: _search,
          focusNode: _searchFocus,
          hint: 'Search clips',
          onChanged: _onSearch,
        ),
        const SizedBox(height: ArcadeTokens.space12),
        Wrap(spacing: ArcadeTokens.space8, runSpacing: ArcadeTokens.space8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ArcadeSegmented<_ClipFilter>(
              options: const [
                (_ClipFilter.all, 'All'),
                (_ClipFilter.text, 'Text'),
                (_ClipFilter.images, 'Images'),
                (_ClipFilter.links, 'Links'),
                (_ClipFilter.files, 'Files'),
                (_ClipFilter.pinned, 'Pinned'),
              ],
              value: _filter,
              onChanged: (value) => setState(() => _filter = value),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Filter by source device',
            onSelected: (value) => setState(() => _source = value),
            itemBuilder: (_) => [
              const PopupMenuItem(value: '', child: Text('All devices')),
              for (final source in sources.entries) PopupMenuItem(value: source.key, child: Text(source.value)),
            ],
            child: IgnorePointer(
              child: ArcadeButton(
                label: _source.isEmpty ? 'All devices' : sources[_source] ?? 'Device',
                icon: 'monitor',
                small: true,
                onPressed: () {},
              ),
            ),
          ),
        ]),
        const SizedBox(height: ArcadeTokens.space16),
        if (controller.historyLoading && items.isNotEmpty)
          const Padding(padding: EdgeInsets.only(bottom: ArcadeTokens.space8), child: LinearProgressIndicator(minHeight: 2)),
        list,
        if (controller.hasMoreHistory)
          Padding(
            padding: const EdgeInsets.only(top: ArcadeTokens.space12),
            child: Center(
              child: ArcadeButton(
                label: 'Load more clips',
                variant: ArcadeButtonVariant.ghost,
                onPressed: controller.historyLoading ? null : controller.loadMoreHistory,
              ),
            ),
          ),
        if (items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: ArcadeTokens.space12),
            child: Row(children: [
              Text('${formatCount(items.length)} ${items.length == 1 ? 'clip' : 'clips'}',
                  style: ArcadeTokens.textSmall.copyWith(color: c.faint)),
              const Spacer(),
              if (controller.desktopCapabilities?.globalShortcut == true && MediaQuery.sizeOf(context).width >= 1000)
                InkWell(
                  onTap: controller.openOverlay,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('Quick picker', style: ArcadeTokens.textSmall.copyWith(color: c.faint)),
                    const SizedBox(width: ArcadeTokens.space6),
                    ArcadeKeyCombo(_shortcutKeys(controller.shortcut)),
                  ]),
                ),
            ]),
          ),
      ]),
    );
  }

  void _onSearch(String value) {
    setState(() {});
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 160), () => widget.controller.refreshHistory(query: value));
  }
}

/// A stored shortcut ("CTRL+ALT+V") as key chip labels.
List<String> _shortcutKeys(String shortcut) => shortcut
    .split('+')
    .where((part) => part.trim().isNotEmpty)
    .map((part) => switch (part.trim().toUpperCase()) {
          'CTRL' || 'CONTROL' => Platform.isMacOS ? '⌃' : 'Ctrl',
          'ALT' || 'OPTION' => Platform.isMacOS ? '⌥' : 'Alt',
          'SHIFT' => Platform.isMacOS ? '⇧' : 'Shift',
          'META' || 'SUPER' || 'CMD' || 'COMMAND' => Platform.isMacOS ? '⌘' : 'Super',
          'SPACE' => 'Space',
          final key => key.length == 1 ? key : key[0] + key.substring(1).toLowerCase(),
        })
    .toList();

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
    final c = arcadeColors(context);
    return ListenableBuilder(
      listenable: _RelativeClock.instance,
      builder: (context, _) => ArcadeRow(
        title: item.preview.isEmpty ? 'Empty clip' : item.preview.split('\n').first,
        subtitle: '${item.sourceName} · ${_relativeTime(item.createdAt)}'
            '${item.size > 0 && item.hasBinaryContent ? ' · ${formatSize(item.size)}' : ''}',
        onTap: onTap,
        leading: ArcadeGlyphTile(
          child: item.kind == 'image'
              ? ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(ArcadeTokens.radiusTile)),
                  child: ClipThumbnail(controller: controller, item: item))
              : ArcadeIcon(clipGlyph(item.kind)),
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (item.pinned)
            Padding(
              padding: const EdgeInsets.only(right: ArcadeTokens.space4),
              child: ArcadeIcon('pin', color: c.accent, semanticLabel: 'Pinned'),
            ),
          ArcadeButton(label: 'Copy to this device', icon: 'copy', iconOnly: true, small: true, variant: ArcadeButtonVariant.ghost, onPressed: onCopy),
          PopupMenuButton<String>(
            tooltip: 'Clip actions',
            icon: ArcadeIcon('more', color: c.muted),
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
              const PopupMenuItem(value: 'inspect', child: Text('Inspect clip')),
              PopupMenuItem(value: 'pin', child: Text(item.pinned ? 'Unpin clip' : 'Pin clip')),
              const PopupMenuItem(value: 'resend', child: Text('Share again')),
              for (final action in controller.linkActions(item))
                PopupMenuItem(
                    value: 'link:${action.peer}/${action.action}',
                    enabled: action.enabled,
                    child: LinkActionLabel(action: action, item: item)),
              PopupMenuItem(value: 'delete', child: Text('Delete clip', style: TextStyle(color: c.danger))),
            ],
          ),
        ]),
      ),
    );
  }
}
