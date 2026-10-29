part of '../app.dart';

/// The quick overlay (Template B): a 44 px search field, 40 px clip rows
/// and a hint bar. Keyboard first: arrows move, Enter pastes, Ctrl/⌘+Enter
/// pastes as plain text, Esc clears the search and then closes.
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

  bool get _picking => widget.controller.linkPickFor != null;

  int _selectedIndex(List<ClipboardItem> items) {
    if (items.isEmpty) return 0;
    final index = items.indexWhere((item) => item.id == _selectedItemId);
    return index < 0 ? 0 : index;
  }

  void _selectCurrent({bool plainText = false}) {
    final items = _visible;
    if (items.isEmpty) return;
    unawaited(widget.controller.selectOverlayItem(items[_selectedIndex(items)],
        plainText: plainText && !_picking));
  }

  void _revealSelection(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      const rowExtent = ArcadeTokens.rowOverlay + ArcadeTokens.space2;
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
    final c = arcadeColors(context);
    final controller = widget.controller;
    final items = _visible;
    final selectedIndex = _selectedIndex(items);
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl';
    final enterLabel = _picking
        ? 'Choose'
        : controller.desktopCapabilities?.paste == false
            ? 'Copy'
            : 'Paste';
    return Scaffold(
      backgroundColor: c.bg,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: c.panel,
              border: Border.all(color: c.line),
              borderRadius: const BorderRadius.all(
                  Radius.circular(ArcadeTokens.radiusLg)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        ArcadeTokens.space10,
                        ArcadeTokens.space10,
                        ArcadeTokens.space10,
                        ArcadeTokens.space6),
                    child: CallbackShortcuts(
                      bindings: {
                        for (final key in const [
                          LogicalKeyboardKey.arrowUp,
                          LogicalKeyboardKey.arrowDown,
                          LogicalKeyboardKey.home,
                          LogicalKeyboardKey.end,
                        ])
                          SingleActivator(key): () => _handleKey(key),
                        const SingleActivator(LogicalKeyboardKey.enter,
                                control: true):
                            () => _selectCurrent(plainText: true),
                        const SingleActivator(LogicalKeyboardKey.enter,
                            meta: true): () => _selectCurrent(plainText: true),
                      },
                      child: ArcadeSearchField(
                        controller: _search,
                        focusNode: _focus,
                        height: ArcadeTokens.overlaySearch,
                        hint: _picking
                            ? 'Choose a clip for ${controller.linkPickFor}'
                            : 'Search clips',
                        onSubmitted: (_) => _selectCurrent(),
                        onEscape: controller.dismissOverlay,
                        onChanged: (value) {
                          setState(() => _selectedItemId = null);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted && _scroll.hasClients) {
                              _scroll.jumpTo(0);
                            }
                          });
                          unawaited(controller.searchOverlay(value));
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    height: ArcadeTokens.space2,
                    child: controller.overlaySearchLoading
                        ? const LinearProgressIndicator(
                            minHeight: ArcadeTokens.space2)
                        : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: ArcadeTokens.space10),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinkWorkStatus(controller: controller),
                          WaitingPhoto(controller: controller),
                          if (controller.error case final error?)
                            Padding(
                              padding: const EdgeInsets.only(
                                  top: ArcadeTokens.space6),
                              child:
                                  ArcadeNotice(error, tone: ArcadeTone.danger),
                            ),
                          if (controller.notice case final notice?)
                            Padding(
                              padding: const EdgeInsets.only(
                                  top: ArcadeTokens.space6),
                              child: ArcadeNotice(notice),
                            ),
                        ]),
                  ),
                  Expanded(
                    child: items.isEmpty
                        ? Center(
                            child: SingleChildScrollView(
                              padding:
                                  const EdgeInsets.all(ArcadeTokens.space16),
                              child: ArcadeEmptyState(
                                icon: _search.text.isEmpty
                                    ? 'clipboard'
                                    : 'search',
                                title: _search.text.isEmpty
                                    ? 'Nothing copied yet'
                                    : 'No matching clips',
                                message: _search.text.isEmpty
                                    ? 'Copy something on any of your devices and it shows up here.'
                                    : 'Try a different word, or press Esc to clear the search.',
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(ArcadeTokens.space6),
                            itemExtent:
                                ArcadeTokens.rowOverlay + ArcadeTokens.space2,
                            itemCount: items.length,
                            itemBuilder: (context, index) => Padding(
                              padding: const EdgeInsets.only(
                                  bottom: ArcadeTokens.space2),
                              child: _OverlayClipRow(
                                item: items[index],
                                selected: index == selectedIndex,
                                onTap: () => unawaited(
                                    controller.selectOverlayItem(items[index])),
                                onHover: (hovering) {
                                  if (hovering) {
                                    setState(() =>
                                        _selectedItemId = items[index].id);
                                  }
                                },
                              ),
                            ),
                          ),
                  ),
                  if (items.isNotEmpty &&
                      controller.linkActions(items[selectedIndex]).isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: ArcadeTokens.space10,
                          vertical: ArcadeTokens.space6),
                      decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: c.line))),
                      child: Wrap(
                          spacing: ArcadeTokens.space6,
                          runSpacing: ArcadeTokens.space6,
                          children: [
                            for (final action
                                in controller.linkActions(items[selectedIndex]))
                              _OverlayLinkAction(
                                action: action,
                                onPressed: action.enabled
                                    ? () => controller.invokeItemAction(
                                        items[selectedIndex], action)
                                    : null,
                              ),
                          ]),
                    ),
                  ArcadeHintBar([
                    (const ['↵'], enterLabel),
                    if (!_picking) ([mod, '↵'], 'Paste as plain text'),
                    (const ['Esc'], 'Close'),
                  ]),
                ]),
          ),
        ),
      ),
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed &&
        keyboard.isAltPressed &&
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
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.controller.dismissOverlay();
      return KeyEventResult.handled;
    }
    return _handleKey(event.logicalKey);
  }

  KeyEventResult _handleKey(LogicalKeyboardKey key) {
    final items = _visible;
    if (items.isEmpty) return KeyEventResult.ignored;
    final int? next = switch (key) {
      LogicalKeyboardKey.arrowDown =>
        (_selectedIndex(items) + 1) % items.length,
      LogicalKeyboardKey.arrowUp =>
        (_selectedIndex(items) - 1 + items.length) % items.length,
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => items.length - 1,
      _ => null,
    };
    if (next != null) {
      setState(() => _selectedItemId = items[next].id);
      _revealSelection(next);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter) {
      _selectCurrent();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

class _OverlayClipRow extends StatelessWidget {
  const _OverlayClipRow(
      {required this.item,
      required this.selected,
      required this.onTap,
      required this.onHover});

  final ClipboardItem item;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return ListenableBuilder(
      listenable: _RelativeClock.instance,
      builder: (context, _) => ArcadeOverlayRow(
        title: item.preview.replaceAll(RegExp(r'\s+'), ' ').trim(),
        leading: ArcadeIcon(clipGlyph(item.kind),
            color: selected ? c.accent : c.muted),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (item.pinned) ...[
            ArcadeIcon('pin',
                size: ArcadeTokens.iconSize,
                color: c.faint,
                semanticLabel: 'Pinned'),
            const SizedBox(width: ArcadeTokens.space6),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text('${item.sourceName} · ${_relativeTime(item.createdAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ArcadeTokens.textCaption.copyWith(color: c.faint)),
          ),
        ]),
        selected: selected,
        onTap: onTap,
        onHover: onHover,
      ),
    );
  }
}

/// A Link action for the selected clip ("Send to Shelf"), with its
/// Ctrl+Alt shortcut as key chips.
class _OverlayLinkAction extends StatelessWidget {
  const _OverlayLinkAction({required this.action, required this.onPressed});

  final LinkItemAction action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Tooltip(
      message: action.disabledReason ?? action.title,
      child: InkWell(
        onTap: onPressed,
        borderRadius:
            const BorderRadius.all(Radius.circular(ArcadeTokens.radiusSm)),
        hoverColor: c.hover,
        child: Opacity(
          opacity: onPressed == null ? 0.5 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: ArcadeTokens.space8, vertical: ArcadeTokens.space4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ArcadeGlyph(action.peer, size: ArcadeTokens.iconSize),
              const SizedBox(width: ArcadeTokens.space6),
              Text(action.title,
                  style: ArcadeTokens.textControl.copyWith(color: c.text)),
              const SizedBox(width: ArcadeTokens.space8),
              ArcadeKeyCombo(['Ctrl', 'Alt', action.shortcut]),
            ]),
          ),
        ),
      ),
    );
  }
}
