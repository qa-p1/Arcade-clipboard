part of '../app.dart';

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
                ListenableBuilder(
                    listenable: _RelativeClock.instance,
                    builder: (context, _) => Text(
                        '${item.sourceName} · ${_relativeTime(item.createdAt)}${item.size > 0 && item.hasBinaryContent ? ' · ${formatBytes(item.size)}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant))),
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
