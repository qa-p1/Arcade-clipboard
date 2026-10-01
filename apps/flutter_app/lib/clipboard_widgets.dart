import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'models.dart';
import 'services/app_controller.dart';

IconData clipIcon(String kind) => switch (kind) {
      'url' => Icons.link_rounded,
      'image' => Icons.image_outlined,
      'file' || 'files' => Icons.insert_drive_file_outlined,
      'rich_text' || 'html' => Icons.article_outlined,
      _ => Icons.notes_rounded,
    };

String clipKindLabel(String kind) => switch (kind) {
      'url' => 'Link',
      'image' => 'Image',
      'file' => 'File',
      'files' => 'Files',
      'rich_text' || 'html' => 'Rich text',
      _ => 'Text',
    };

String formatBytes(int size) {
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) {
    return '${(size / 1024).toStringAsFixed(size < 10240 ? 1 : 0)} KB';
  }
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

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
            : 'Could not open those files. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('Add a clip'),
        content: SizedBox(
          width: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _text,
                autofocus: true,
                minLines: 5,
                maxLines: 10,
                decoration:
                    const InputDecoration(hintText: 'Text or a link to share'),
                enabled: !_busy,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : _pickFiles,
                  icon: const Icon(Icons.attach_file_rounded, size: 18),
                  label: const Text('Choose image or files'),
                ),
              ),
              Text('Up to 16 MB per clip.',
                  style: Theme.of(context).textTheme.bodySmall),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              if (_busy)
                const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(minHeight: 2)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _busy ? null : _submit, child: const Text('Add clip')),
        ],
      );
}

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
            _notice = 'Could not save this file. Choose another location.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: Row(children: [
        Icon(clipIcon(item.kind), size: 22),
        const SizedBox(width: 10),
        Text(clipKindLabel(item.kind))
      ]),
      content: SizedBox(
        width: 560,
        child: FutureBuilder<ClipboardPayload>(
          future: _payload,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('This clip could not be loaded.'),
                  TextButton(
                      onPressed: () => setState(
                          () => _payload = widget.controller.loadPayload(item)),
                      child: const Text('Retry')),
                ],
              );
            }
            if (!snapshot.hasData) {
              return const Padding(
                  padding: EdgeInsets.all(32),
                  child:
                      Center(child: CircularProgressIndicator(strokeWidth: 2)));
            }
            final payload = snapshot.data!;
            final images = payload.representations.where((value) =>
                value.mimeType.startsWith('image/') && value.bytes != null);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                    '${item.sourceName} · ${item.createdAt.toLocal().toString().substring(0, 16)}${item.size > 0 ? ' · ${formatBytes(item.size)}' : ''}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 18),
                if (payload.kind == 'image')
                  for (final image in images)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(image.bytes!,
                          height: 280,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stack) => const Text(
                              'Image preview is unavailable. You can still save the file.')),
                    ),
                if (payload.text.isNotEmpty)
                  ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 350),
                      child: SingleChildScrollView(
                          child: SelectableText(payload.text,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(height: 1.55)))),
                if (item.hasBinaryContent)
                  for (final representation in payload.representations)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                          representation.name ?? clipKindLabel(payload.kind),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(formatBytes(
                          representation.bytes?.length ?? representation.size)),
                      trailing: TextButton.icon(
                        onPressed: () => _save(representation),
                        icon: Icon(
                            widget.controller.desktopAvailable
                                ? Icons.download_rounded
                                : Icons.ios_share_rounded,
                            size: 17),
                        label: Text(widget.controller.desktopAvailable
                            ? 'Save'
                            : 'Share'),
                      ),
                    ),
                if (_notice != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_notice!, style: theme.textTheme.bodySmall)),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close')),
        if (!(item.kind == 'file' || item.kind == 'files') ||
            widget.controller.desktopAvailable)
          FilledButton.tonalIcon(
              onPressed: () async {
                await widget.controller.copyLocally(item);
                if (mounted) {
                  setState(() => _notice =
                      widget.controller.error ?? 'Copied to this device.');
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy')),
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
          borderRadius: BorderRadius.circular(8),
          child: FutureBuilder<Uint8List?>(
              future: _image,
              builder: (_, snapshot) => snapshot.data != null
                  ? Image.memory(snapshot.data!,
                      fit: BoxFit.cover,
                      cacheWidth: 160,
                      frameBuilder: (context, child, frame, synchronous) =>
                          frame != null
                              ? child
                              : const Icon(Icons.image_outlined, size: 18),
                      errorBuilder: (context, error, stack) =>
                          const Icon(Icons.image_outlined, size: 18))
                  : const Icon(Icons.image_outlined, size: 18)),
        ),
      );
}
