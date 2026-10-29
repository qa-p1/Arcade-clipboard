import 'package:flutter/material.dart';

import 'design/arcade_theme.dart';
import 'design/arcade_widgets.dart';
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
  /// [peer]'s accent from the kit, for the current brightness.
  static Color accentOf(BuildContext context, String peer) {
    final accent = arcadeAccents[peer];
    if (accent == null) return arcadeColors(context).muted;
    return Theme.of(context).brightness == Brightness.dark ? accent.dark : accent.light;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
          painter: _GlyphPainter(
              peer, color ?? accentOf(context, peer))));
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
        p.addRRect(const RRect.fromLTRBXY(3.25, 4.75, 6.75, 8.75, 0.75, 0.75));
        p.addRRect(const RRect.fromLTRBXY(8.75, 2, 12.75, 8.75, 0.75, 0.75));
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
        ArcadeKeyCombo(['Ctrl', 'Alt', action.shortcut]),
      ]));
}

class LinkWorkStatus extends StatelessWidget {
  const LinkWorkStatus({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    if (!controller.link.busy) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: ArcadeTokens.space12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LinearProgressIndicator(value: controller.link.progressFraction, minHeight: 2),
        const SizedBox(height: ArcadeTokens.space6),
        Row(children: [
          Expanded(
              child: Text(controller.link.progressMessage ?? 'Working…',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: ArcadeTokens.textSmall.copyWith(color: arcadeColors(context).muted))),
          ArcadeButton(label: 'Cancel', small: true, variant: ArcadeButtonVariant.ghost, onPressed: controller.link.cancel),
        ]),
      ]),
    );
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
    return Padding(
      padding: const EdgeInsets.only(bottom: ArcadeTokens.space12),
      child: ArcadeNotice(
        'This image is too large to sync. Compress it with another Arcade app, or discard it.',
        tone: ArcadeTone.warn,
        action: Wrap(spacing: ArcadeTokens.space8, children: [
          for (final action in offers)
            Tooltip(
                message: action.disabledReason ?? 'Compress this photo; the result joins your devices.',
                child: ArcadeButton(
                    label: '${action.title} ↗',
                    small: true,
                    onPressed: action.enabled ? () => controller.invokeItemAction(photo, action) : null)),
          ArcadeButton(
              label: 'Discard', small: true, variant: ArcadeButtonVariant.ghost, onPressed: controller.link.busy ? null : controller.dismissWaitingPhoto),
        ]),
      ),
    );
  }
}

/// Settings › Connected apps: the shared Link page (STANDARD §6). The master
/// switch, a notice while it is off, one row per other Arcade app, then the
/// connection details and "How it works".
class ConnectedAppsSection extends StatelessWidget {
  const ConnectedAppsSection({super.key, required this.controller});
  final AppController controller;

  static const guideUrl = 'https://github.com/qa-p1/Arcade-clipboard/blob/main/docs/user/with-other-apps.md';

  @override
  Widget build(BuildContext context) {
    final link = controller.link;
    final c = arcadeColors(context);
    final busy = controller.working || link.busy;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!link.enabled)
        Padding(
          padding: const EdgeInsets.only(bottom: ArcadeTokens.space12),
          child: ArcadeNotice('Connections are off in this app.',
              tone: ArcadeTone.warn,
              action: ArcadeButton(label: 'Turn on', small: true, onPressed: busy ? null : () => controller.setLinkEnabled(true))),
        ),
      ArcadeListSection(title: 'Connected apps', children: [
        ArcadeSwitchRow(
          title: 'Connect with other Arcade apps',
          subtitle: 'Send clips to other apps and take results back into your history.',
          value: link.enabled,
          onChanged: controller.working ? null : controller.setLinkEnabled,
        ),
        for (final peer in link.peers)
          Builder(builder: (context) {
            final id = peer['id'] as String;
            final state = peer['state'] as String? ?? 'Not installed';
            final (label, tone) = switch (state) {
              'Running' => ('Connected', ArcadeTone.ok),
              'Not installed' => ('Not installed', ArcadeTone.neutral),
              _ => ('Not running', ArcadeTone.neutral),
            };
            return ArcadeRow(
              title: peer['name'] as String? ?? id,
              subtitle: switch ((peer['link_enabled'], state, peer['version'])) {
                (false, _, _) => 'Connections are off in that app.',
                (_, 'Not installed', _) => peer['pitch'] as String? ?? '',
                (_, _, final String version) when version.isNotEmpty => 'Version $version',
                _ => null,
              },
              leading: ArcadeGlyphTile(child: ArcadeGlyph(id)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                ArcadeBadge(label, tone: tone, dot: tone == ArcadeTone.ok),
                const SizedBox(width: ArcadeTokens.space8),
                if (state == 'Not installed')
                  ArcadeButton(label: 'Install', small: true, onPressed: busy ? null : () => controller.getArcadeApp(id))
                else
                  Semantics(
                    label: 'Use ${peer['name']} with Arcade Clipboard',
                    child: Switch(
                      value: link.uses(id),
                      onChanged: !link.enabled || controller.working ? null : (value) => controller.setLinkPeerEnabled(id, value),
                    ),
                  ),
              ]),
            );
          }),
      ]),
      LinkWorkStatus(controller: controller),
      Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Connection details', style: ArcadeTokens.textSmall.copyWith(color: c.muted)),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                'Registry: ${link.diagnostics['registry'] ?? 'Starting…'}\n'
                'Endpoint: ${link.diagnostics['listening'] == true ? 'Listening' : 'Off'}\n'
                'Registry notifications: ${link.diagnostics['watching'] == true ? 'On' : 'Unavailable'}\n'
                'Last error: ${link.diagnostics['last_error'] ?? 'None'}\n'
                '${[for (final peer in link.peers) '${peer['name']}: ${peer['state']}${peer['state'] == 'Running' ? ' ${peer['version']}' : ''}'].join('\n')}',
                style: ArcadeTokens.textSmall.copyWith(color: c.muted),
              ),
            ),
          ],
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: ArcadeButton(label: 'How it works', variant: ArcadeButtonVariant.ghost, small: true, onPressed: () => controller.openUrl(guideUrl)),
      ),
    ]);
  }
}
