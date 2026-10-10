import 'package:flutter/material.dart';

import 'models.dart';
import 'services/app_controller.dart';
import 'services/link_service.dart';

/// Canvas copies of the shared 16px SVG paths, bundled in assets/arcade.
/// No asset reads occur when a menu opens.
class ArcadeGlyph extends StatelessWidget {
  const ArcadeGlyph(this.peer, {super.key, this.color, this.size = 16});
  final String peer;
  final Color? color;
  final double size;
  static const accents = {
    'arcade.box': Color(0xFF7C5CFF),
    'arcade.lens': Color(0xFF2BB3A3),
    'arcade.look': Color(0xFF3B82F6),
    'arcade.wheel': Color(0xFFF59E0B),
    'arcade.tools': Color(0xFF64748B),
    'arcade.shelf': Color(0xFF94A8FF),
    'arcade.find': Color(0xFF22C55E),
  };
  @override
  Widget build(BuildContext context) => SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
          painter: _GlyphPainter(
              peer, color ?? Theme.of(context).colorScheme.onSurface)));
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.peer, this.color);
  final String peer;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 16, size.height / 16);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final p = Path();
    switch (peer) {
      case 'arcade.box':
        p.moveTo(8, 1.75);
        p.lineTo(14, 4.75);
        p.lineTo(14, 11.25);
        p.lineTo(8, 14.25);
        p.lineTo(2, 11.25);
        p.lineTo(2, 4.75);
        p.close();
        p.moveTo(2, 4.75);
        p.lineTo(8, 7.75);
        p.lineTo(14, 4.75);
        p.moveTo(8, 7.75);
        p.lineTo(8, 14.25);
      case 'arcade.look':
        p.moveTo(1.25, 8);
        p.cubicTo(3.75, 3.25, 8, 0, 14.75, 8);
        p.cubicTo(12.25, 12.75, 8, 16, 1.25, 8);
        p.close();
        canvas.drawCircle(const Offset(8, 8), 2, paint);
      case 'arcade.lens':
        for (var i = 0; i < 4; i++) {
          canvas.save();
          canvas.translate(8, 8);
          canvas.rotate(i * 1.57079632679);
          canvas.translate(-8, -8);
          canvas.drawPath(
              Path()
                ..moveTo(1.75, 5)
                ..lineTo(1.75, 2.75)
                ..quadraticBezierTo(1.75, 1.75, 2.75, 1.75)
                ..lineTo(5, 1.75),
              paint);
          canvas.restore();
        }
        canvas.drawCircle(const Offset(8, 8), 2.25, paint);
      case 'arcade.tools':
        canvas.drawCircle(const Offset(8, 8), 5.25, paint);
        p.moveTo(5, 8);
        p.lineTo(11, 8);
        p.moveTo(8, 5);
        p.lineTo(8, 11);
      case 'arcade.wheel':
        canvas.drawCircle(const Offset(8, 8), 6.25, paint);
        canvas.drawCircle(const Offset(8, 8), 1.75, paint);
        p.moveTo(8, 1.75);
        p.lineTo(8, 6.25);
        p.moveTo(8, 9.75);
        p.lineTo(8, 14.25);
        p.moveTo(1.75, 8);
        p.lineTo(6.25, 8);
        p.moveTo(9.75, 8);
        p.lineTo(14.25, 8);
      case 'arcade.shelf':
        p.moveTo(1.75, 10.75);
        p.lineTo(14.25, 10.75);
        p.lineTo(14.25, 14.25);
        p.lineTo(1.75, 14.25);
        p.close();
        p.addRRect(RRect.fromLTRBXY(3.25, 4.75, 6.75, 8.75, 0.75, 0.75));
        p.addRRect(RRect.fromLTRBXY(8.75, 2, 12.75, 8.75, 0.75, 0.75));
      case 'arcade.find':
        canvas.drawCircle(const Offset(7, 7), 4.75, paint);
        p.moveTo(10.5, 10.5);
        p.lineTo(14.25, 14.25);
    }
    canvas.drawPath(p, paint);
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      peer != old.peer || color != old.color;
}

class LinkActionLabel extends StatelessWidget {
  const LinkActionLabel({super.key, required this.action, required this.item});
  final LinkItemAction action;
  final ClipboardItem item;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 310,
      child: Row(children: [
        ArcadeGlyph(action.peer),
        const SizedBox(width: 10),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
              Text('${action.title} ↗'),
              Text(
                  action.disabledReason ??
                      '${item.preview}${action.importsResult ? ' · Result joins your devices' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ])),
        const SizedBox(width: 8),
        Text('Ctrl+Alt+${action.shortcut}',
            style: Theme.of(context).textTheme.labelSmall),
      ]));
}

class LinkWorkStatus extends StatelessWidget {
  const LinkWorkStatus({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    if (!controller.link.busy) return const SizedBox.shrink();
    return Column(children: [
      LinearProgressIndicator(
          value: controller.link.progressFraction, minHeight: 2),
      Row(children: [
        Expanded(
            child: Text(controller.link.progressMessage ?? 'Working…',
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        TextButton(
            onPressed: controller.link.cancel, child: const Text('Cancel'))
      ]),
    ]);
  }
}

class WaitingPhoto extends StatelessWidget {
  const WaitingPhoto({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final photo = controller.waitingPhoto;
    if (photo == null) return const SizedBox.shrink();
    final offers = controller.linkActions(photo);
    return Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Image too large to sync'),
          for (final action in offers)
            Tooltip(
                message: action.disabledReason ??
                    'Compress this photo; the result joins your devices.',
                child: TextButton.icon(
                    icon: ArcadeGlyph(action.peer),
                    label: Text('${action.title} ↗'),
                    onPressed: action.enabled
                        ? () => controller.invokeItemAction(photo, action)
                        : null)),
          TextButton(
              onPressed:
                  controller.link.busy ? null : controller.dismissWaitingPhoto,
              child: const Text('Discard')),
        ]);
  }
}

class ConnectedAppsPage extends StatelessWidget {
  const ConnectedAppsPage({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final link = controller.link;
        final dark = Theme.of(context).brightness == Brightness.dark;
        // Shared tokens.json: panel radius 12, light/dark raised surfaces.
        final raised = dark ? const Color(0xFF1C2027) : const Color(0xFFF5F6F8);
        return Scaffold(
            appBar: AppBar(title: const Text('Connected apps')),
            body: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child:
                        ListView(padding: const EdgeInsets.all(20), children: [
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Connect with other Arcade apps'),
                        value: link.enabled,
                        onChanged: controller.working
                            ? null
                            : controller.setLinkEnabled,
                      ),
                      const SizedBox(height: 16),
                      for (final peer in link.peers)
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                              color: raised,
                              borderRadius: BorderRadius.circular(12)),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  ArcadeGlyph(peer['id'] as String,
                                      color: ArcadeGlyph.accents[peer['id']]),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text(peer['name'] as String,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium)),
                                  Text(
                                      '${peer['state']}${peer['state'] == 'Running' ? ' · v${peer['version']}' : ''}'),
                                ]),
                                if (peer['state'] == 'Not installed') ...[
                                  const SizedBox(height: 8),
                                  Text(peer['pitch'] as String),
                                  TextButton(
                                      onPressed: controller.working || link.busy
                                          ? null
                                          : () => controller.getArcadeApp(
                                              peer['id'] as String),
                                      child: const Text('Get')),
                                ] else ...[
                                  if (peer['link_enabled'] == false)
                                    const Padding(
                                        padding: EdgeInsets.only(top: 8),
                                        child: Text(
                                            'Connections are off in this app.')),
                                  Material(
                                      color: Colors.transparent,
                                      child: SwitchListTile.adaptive(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text(
                                            'Use with Arcade Clipboard'),
                                        value: link.uses(peer['id'] as String),
                                        onChanged: !link.enabled ||
                                                controller.working
                                            ? null
                                            : (value) =>
                                                controller.setLinkPeerEnabled(
                                                    peer['id'] as String,
                                                    value),
                                      )),
                                ],
                              ]),
                        ),
                      LinkWorkStatus(controller: controller),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Diagnostics'),
                        children: [
                          Align(
                              alignment: Alignment.centerLeft,
                              child: SelectableText(
                                'Registry: ${link.diagnostics['registry'] ?? 'Starting…'}\n'
                                'Endpoint: ${link.diagnostics['listening'] == true ? 'Listening' : 'Off'}\n'
                                'Registry notifications: ${link.diagnostics['watching'] == true ? 'On' : 'Unavailable'}\n'
                                'Last error: ${link.diagnostics['last_error'] ?? 'None'}',
                              )),
                        ],
                      ),
                      if (controller.error != null)
                        Text(controller.error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                    ]))));
      });
}
