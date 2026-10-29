import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'design/arcade_format.dart';
import 'design/arcade_icons.dart';
import 'design/arcade_theme.dart';
import 'design/arcade_widgets.dart';
import 'models.dart';
import 'services/app_controller.dart';

/// The kit glyph for a clip kind.
String clipGlyph(String kind) => switch (kind) {
      'url' => 'link',
      'image' => 'image',
      'file' => 'file',
      'files' => 'folder',
      'rich_text' || 'html' => 'document',
      _ => 'type',
    };

String clipKindLabel(String kind) => switch (kind) {
      'url' => 'Link',
      'image' => 'Image',
      'file' => 'File',
      'files' => 'Files',
      'rich_text' || 'html' => 'Rich text',
      _ => 'Text',
    };

Future<void> showAddClip(BuildContext context, AppController controller) =>
    showDialog<void>(
      context: context,
      builder: (_) => AddClipDialog(controller: controller),
    );

Future<void> showClipDetail(
        BuildContext context, AppController controller, ClipboardItem item) =>
    showDialog<void>(
      context: context,
      builder: (_) => ClipDetailDialog(controller: controller, item: item),
    );

class AddClipDialog extends StatefulWidget {
  const AddClipDialog({super.key, required this.controller});
  final AppController controller;

  @override
  State<AddClipDialog> createState() => _AddClipDialogState();
}

class _AddClipDialogState extends State<AddClipDialog> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.controller.addText(_text.text);
    if (!mounted) return;
    if (widget.controller.error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = widget.controller.error;
      });
    }
  }

  Future<void> _pickFiles() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final files = await openFiles();
      if (files.isEmpty) return;
      var total = 0;
      final representations = <ClipRepresentation>[];
      for (final file in files) {
        total += await file.length();
        if (total > 16 * 1024 * 1024) {
          throw const FormatException('Choose files under 16 MB in total.');
        }
        final extension = file.name.toLowerCase().split('.').last;
        final mime = switch (extension) {
          'png' => 'image/png',
          'jpg' || 'jpeg' => 'image/jpeg',
          'txt' => 'text/plain',
          'pdf' => 'application/pdf',
          'html' || 'htm' => 'text/html',
          _ => 'application/octet-stream',
        };
        representations.add(ClipRepresentation(
            mimeType: mime, name: file.name, bytes: await file.readAsBytes()));
      }
      final image = representations.length == 1 &&
          representations.first.mimeType.startsWith('image/');
      await widget.controller.addRepresentations(
        representations: representations,
        kind: image
            ? 'image'
            : representations.length == 1
                ? 'file'
                : 'files',
      );
      if (!mounted) return;
      if (widget.controller.error != null) {
        setState(() => _error = widget.controller.error);
      } else {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is FormatException
            ? error.message
            : "Couldn't open those files. Try again.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return AlertDialog(
      scrollable: true,
      title: const Text('Add a clip'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 5,
            maxLines: 10,
            style: ArcadeTokens.textBody.copyWith(color: c.text),
            decoration:
                const InputDecoration(hintText: 'Text or a link to share'),
            enabled: !_busy,
          ),
          const SizedBox(height: ArcadeTokens.space12),
          Row(children: [
            ArcadeButton(
                label: 'Choose image or files…',
                icon: 'file',
                small: true,
                onPressed: _busy ? null : _pickFiles),
            const SizedBox(width: ArcadeTokens.space10),
            Flexible(
                child: Text('Up to 16 MB per clip.',
                    style: ArcadeTokens.textSmall.copyWith(color: c.faint))),
          ]),
          if (_error case final error?)
            Padding(
                padding: const EdgeInsets.only(top: ArcadeTokens.space12),
                child: ArcadeNotice(error, tone: ArcadeTone.danger)),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: ArcadeTokens.space12),
              child: LinearProgressIndicator(minHeight: ArcadeTokens.space2),
            ),
        ]),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actionsPadding: _dialogActionsPadding,
      actions: [
        Wrap(
            spacing: ArcadeTokens.space8,
            alignment: WrapAlignment.end,
            children: [
              ArcadeButton(
                  label: 'Cancel',
                  onPressed: _busy ? null : () => Navigator.of(context).pop()),
              ArcadeButton(
                  label: 'Add clip',
                  variant: ArcadeButtonVariant.primary,
                  busy: _busy,
                  onPressed: _busy ? null : _submit),
            ]),
      ],
    );
  }
}

const _dialogActionsPadding = EdgeInsets.fromLTRB(
    ArcadeTokens.space20, 0, ArcadeTokens.space20, ArcadeTokens.space20);

class ClipDetailDialog extends StatefulWidget {
  const ClipDetailDialog(
      {super.key, required this.controller, required this.item});
  final AppController controller;
  final ClipboardItem item;

  @override
  State<ClipDetailDialog> createState() => _ClipDetailDialogState();
}

class _ClipDetailDialogState extends State<ClipDetailDialog> {
  late Future<ClipboardPayload> _payload;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _payload = widget.controller.loadPayload(widget.item);
  }

  Future<void> _save(ClipRepresentation representation) async {
    final bytes = representation.bytes;
    if (bytes == null) return;
    try {
      final name = representation.name ??
          (representation.mimeType == 'image/jpeg' ? 'Image.jpg' : 'Image.png');
      if (!widget.controller.desktopAvailable) {
        await widget.controller.exportMobileFile(name: name, bytes: bytes);
        return;
      }
      final location = await getSaveLocation(suggestedName: name);
      if (location == null) return;
      await XFile.fromData(bytes, name: name, mimeType: representation.mimeType)
          .saveTo(location.path);
      if (mounted) setState(() => _notice = 'Saved $name.');
    } catch (_) {
      if (mounted) {
        setState(() =>
            _notice = "Couldn't save this file. Choose another location.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final c = arcadeColors(context);
    final canCopy = !(item.kind == 'file' || item.kind == 'files') ||
        widget.controller.desktopAvailable;
    return AlertDialog(
      scrollable: true,
      title: Row(children: [
        ArcadeGlyphTile(child: ArcadeIcon(clipGlyph(item.kind))),
        const SizedBox(width: ArcadeTokens.space10),
        Flexible(child: Text(clipKindLabel(item.kind))),
      ]),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: FutureBuilder<ClipboardPayload>(
          future: _payload,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return ArcadeNotice(
                "Couldn't load this clip.",
                tone: ArcadeTone.danger,
                action: ArcadeButton(
                  label: 'Retry',
                  small: true,
                  onPressed: () => setState(
                      () => _payload = widget.controller.loadPayload(item)),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [ArcadeSkeletonRow(), ArcadeSkeletonRow()]);
            }
            final payload = snapshot.data!;
            final images = payload.representations.where((value) =>
                value.mimeType.startsWith('image/') && value.bytes != null);
            return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    [
                      item.sourceName,
                      formatRelative(item.createdAt.millisecondsSinceEpoch),
                      if (item.size > 0) formatSize(item.size),
                    ].join(' · '),
                    style: ArcadeTokens.textSmall.copyWith(color: c.muted),
                  ),
                  const SizedBox(height: ArcadeTokens.space16),
                  if (payload.kind == 'image')
                    for (final image in images)
                      ClipRRect(
                        borderRadius: const BorderRadius.all(
                            Radius.circular(ArcadeTokens.radiusMd)),
                        child: Image.memory(image.bytes!,
                            height: 280,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stack) =>
                                const ArcadeNotice(
                                    'Image preview is unavailable. You can still save the file.')),
                      ),
                  if (payload.text.isNotEmpty)
                    Container(
                      constraints: const BoxConstraints(maxHeight: 350),
                      padding: const EdgeInsets.all(ArcadeTokens.space12),
                      decoration: BoxDecoration(
                        color: c.sunken,
                        borderRadius: const BorderRadius.all(
                            Radius.circular(ArcadeTokens.radiusMd)),
                        border: Border.all(color: c.line),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(payload.text,
                            style:
                                ArcadeTokens.textBody.copyWith(color: c.text)),
                      ),
                    ),
                  if (item.hasBinaryContent)
                    for (final representation in payload.representations)
                      ArcadeRow(
                        title:
                            representation.name ?? clipKindLabel(payload.kind),
                        subtitle: formatSize(representation.bytes?.length ??
                            representation.size),
                        leading: ArcadeIcon(
                            representation.mimeType.startsWith('image/')
                                ? 'image'
                                : 'file',
                            color: c.muted),
                        trailing: ArcadeButton(
                          label: widget.controller.desktopAvailable
                              ? 'Save…'
                              : 'Share…',
                          icon: widget.controller.desktopAvailable
                              ? 'download'
                              : 'external',
                          small: true,
                          onPressed: () => _save(representation),
                        ),
                      ),
                  if (_notice case final notice?)
                    Padding(
                        padding:
                            const EdgeInsets.only(top: ArcadeTokens.space12),
                        child: ArcadeNotice(notice)),
                ]);
          },
        ),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actionsPadding: _dialogActionsPadding,
      actions: [
        Wrap(
            spacing: ArcadeTokens.space8,
            alignment: WrapAlignment.end,
            children: [
              ArcadeButton(
                  label: 'Close', onPressed: () => Navigator.of(context).pop()),
              if (canCopy)
                ArcadeButton(
                  label: 'Copy to this device',
                  icon: 'copy',
                  variant: ArcadeButtonVariant.primary,
                  onPressed: () async {
                    await widget.controller.copyLocally(item);
                    if (mounted) {
                      setState(() => _notice =
                          widget.controller.error ?? 'Copied to this device.');
                    }
                  },
                ),
            ]),
      ],
    );
  }
}

class ClipThumbnail extends StatefulWidget {
  const ClipThumbnail(
      {super.key,
      required this.controller,
      required this.item,
      this.size = 40});
  final AppController controller;
  final ClipboardItem item;
  final double size;

  @override
  State<ClipThumbnail> createState() => _ClipThumbnailState();
}

class _ClipThumbnailState extends State<ClipThumbnail> {
  late final Future<Uint8List?> _image =
      widget.controller.loadPayload(widget.item).then((payload) {
    for (final value in payload.representations) {
      if (value.mimeType.startsWith('image/')) return value.bytes;
    }
    return null;
  });

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: widget.size,
        child: ClipRRect(
          borderRadius:
              const BorderRadius.all(Radius.circular(ArcadeTokens.radiusTile)),
          child: FutureBuilder<Uint8List?>(
              future: _image,
              builder: (_, snapshot) => snapshot.data != null
                  ? Image.memory(snapshot.data!,
                      fit: BoxFit.cover,
                      cacheWidth: 160,
                      frameBuilder: (context, child, frame, synchronous) =>
                          frame != null
                              ? child
                              : const ArcadeGlyphTile(
                                  child: ArcadeIcon('image')),
                      errorBuilder: (context, error, stack) =>
                          const ArcadeGlyphTile(child: ArcadeIcon('image')))
                  : const ArcadeGlyphTile(child: ArcadeIcon('image'))),
        ),
      );
}
