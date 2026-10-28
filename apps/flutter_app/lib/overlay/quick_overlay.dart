part of '../app.dart';

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
                              ? 'Arcade Clipboard'
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
                        widget.controller.linkPickFor != null
                            ? 'Choose'
                            : widget.controller.desktopCapabilities?.paste ==
                                    true
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
                        ListenableBuilder(
                            listenable: _RelativeClock.instance,
                            builder: (context, _) => Text(
                                  '${item.sourceName}  ·  ${_relativeTime(item.createdAt)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant),
                                )),
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
