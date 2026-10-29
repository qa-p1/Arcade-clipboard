// The Arcade components for Flutter (STANDARD.md §5): thin wrappers over
// Material widgets, themed by arcadeTheme(brightness, appId). Hand-written;
// arcade_theme.dart and arcade_icons.dart beside it are generated.
// ignore_for_file: public_member_api_docs
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'arcade_icons.dart';
import 'arcade_theme.dart';

/// Button variants (STANDARD.md §5).
enum ArcadeButtonVariant { standard, primary, ghost, danger, destructive }

/// Status tones shared by badges, dots, notices and toasts.
enum ArcadeTone { neutral, ok, warn, danger, accent }

({Color fg, Color bg}) _toneColours(ArcadeColors c, ArcadeTone tone) => switch (tone) {
      ArcadeTone.neutral => (fg: c.muted, bg: c.sunken),
      ArcadeTone.ok => (fg: c.okInk, bg: c.okSoft),
      ArcadeTone.warn => (fg: c.warnInk, bg: c.warnSoft),
      ArcadeTone.danger => (fg: c.dangerInk, bg: c.dangerSoft),
      ArcadeTone.accent => (fg: c.accentInk, bg: c.accentSoft),
    };

const BorderRadius _radiusSm = BorderRadius.all(Radius.circular(ArcadeTokens.radiusSm));
const BorderRadius _radiusMd = BorderRadius.all(Radius.circular(ArcadeTokens.radiusMd));
const BorderRadius _radiusTile = BorderRadius.all(Radius.circular(ArcadeTokens.radiusTile));

/// A button in one of the kit's variants. [icon] is an Arcade icon name. With
/// [iconOnly] the label becomes the tooltip and the accessible name. While
/// [busy] a spinner replaces the icon and the button keeps its width.
class ArcadeButton extends StatelessWidget {
  const ArcadeButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = ArcadeButtonVariant.standard,
    this.icon,
    this.small = false,
    this.iconOnly = false,
    this.busy = false,
    this.focusNode,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final ArcadeButtonVariant variant;
  final String? icon;
  final bool small;
  final bool iconOnly;
  final bool busy;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    final height = small ? ArcadeTokens.controlSm : ArcadeTokens.control;
    final (Color fg, Color bg, Color? border) = switch (variant) {
      ArcadeButtonVariant.primary => (c.accentText, c.accent, null),
      ArcadeButtonVariant.destructive => (c.onFill, c.danger, null),
      ArcadeButtonVariant.danger => (c.dangerInk, c.panel, c.lineStrong),
      ArcadeButtonVariant.ghost => (c.muted, Colors.transparent, null),
      ArcadeButtonVariant.standard => (c.text, c.panel, c.lineStrong),
    };
    final leading = busy
        ? SizedBox.square(dimension: ArcadeTokens.iconSize, child: CircularProgressIndicator(strokeWidth: 1.5, color: fg))
        : icon == null
            ? null
            : ArcadeIcon(icon!, size: ArcadeTokens.iconSize, color: fg);
    final enabled = onPressed != null && !busy;
    final style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size(iconOnly ? height : 0, height)),
      fixedSize: iconOnly ? WidgetStatePropertyAll<Size>(Size.square(height)) : null,
      padding: WidgetStatePropertyAll<EdgeInsets>(
        iconOnly ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: small ? ArcadeTokens.space10 : ArcadeTokens.space12),
      ),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: _radiusSm, side: border == null ? BorderSide.none : BorderSide(color: border)),
      ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return bg == Colors.transparent ? bg : bg.withValues(alpha: 0.5);
        if (states.contains(WidgetState.pressed) || states.contains(WidgetState.hovered)) {
          return switch (variant) {
            ArcadeButtonVariant.primary || ArcadeButtonVariant.destructive => Color.alphaBlend(c.text.withValues(alpha: 0.08), bg),
            _ => c.hover,
          };
        }
        return bg;
      }),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled) ? fg.withValues(alpha: 0.5) : fg,
      ),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      textStyle: const WidgetStatePropertyAll<TextStyle>(ArcadeTokens.textControl),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused) ? BorderSide(color: c.accent, width: ArcadeTokens.focusRing) : null,
      ),
      elevation: const WidgetStatePropertyAll<double>(0),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    final child = iconOnly
        ? (leading ?? Text(label))
        : Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            if (leading != null) ...<Widget>[leading, const SizedBox(width: ArcadeTokens.space6)],
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ]);
    final button = TextButton(
      onPressed: enabled ? onPressed : null,
      style: style,
      focusNode: focusNode,
      autofocus: autofocus,
      child: child,
    );
    final semantic = Semantics(button: true, label: iconOnly ? label : null, enabled: enabled, child: button);
    return iconOnly ? Tooltip(message: label, child: semantic) : semantic;
  }
}

/// A glyph tile: 28, 36 or 52 px, `sunken` fill, rounded.
class ArcadeGlyphTile extends StatelessWidget {
  const ArcadeGlyphTile({super.key, required this.child, this.size = ArcadeTokens.tile, this.color});
  final Widget child;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    final radius = size <= ArcadeTokens.tileSm
        ? ArcadeTokens.radiusTileSm
        : size >= ArcadeTokens.tileLg
            ? ArcadeTokens.radiusTileLg
            : ArcadeTokens.radiusTile;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color ?? c.sunken, borderRadius: BorderRadius.circular(radius)),
      child: IconTheme.merge(data: IconThemeData(color: c.muted), child: child),
    );
  }
}

/// A small status label. With [dot] a leading dot shows the tone.
class ArcadeBadge extends StatelessWidget {
  const ArcadeBadge(this.label, {super.key, this.tone = ArcadeTone.neutral, this.dot = false});
  final String label;
  final ArcadeTone tone;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final t = _toneColours(arcadeColors(context), tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: ArcadeTokens.space8, vertical: ArcadeTokens.space2),
      decoration: BoxDecoration(color: t.bg, borderRadius: BorderRadius.circular(ArcadeTokens.radiusPill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        if (dot) ...<Widget>[ArcadeDot(tone: tone), const SizedBox(width: ArcadeTokens.space6)],
        Text(label, style: ArcadeTokens.textCaption.copyWith(color: t.fg)),
      ]),
    );
  }
}

/// A 7 px status dot.
class ArcadeDot extends StatelessWidget {
  const ArcadeDot({super.key, this.tone = ArcadeTone.ok});
  final ArcadeTone tone;

  @override
  Widget build(BuildContext context) {
    final t = _toneColours(arcadeColors(context), tone);
    return Container(width: 7, height: 7, decoration: BoxDecoration(color: t.fg, shape: BoxShape.circle));
  }
}

/// One key as a chip ("Ctrl", "↵").
class ArcadeKeyChip extends StatelessWidget {
  const ArcadeKeyChip(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Container(
      constraints: const BoxConstraints(minWidth: ArcadeTokens.keyChip, minHeight: ArcadeTokens.keyChip),
      padding: const EdgeInsets.symmetric(horizontal: ArcadeTokens.space6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: const BorderRadius.all(Radius.circular(ArcadeTokens.radiusXs)),
        border: Border(
          top: BorderSide(color: c.lineStrong),
          left: BorderSide(color: c.lineStrong),
          right: BorderSide(color: c.lineStrong),
          bottom: BorderSide(color: c.lineStrong, width: 2),
        ),
      ),
      child: Text(label, style: ArcadeTokens.textCaption.copyWith(color: c.muted)),
    );
  }
}

/// A key combination as chips ("Ctrl" "Alt" "V"); [alternatives] adds "or"
/// between further combinations.
class ArcadeKeyCombo extends StatelessWidget {
  const ArcadeKeyCombo(this.keys, {super.key, this.alternatives = const <List<String>>[]});
  final List<String> keys;
  final List<List<String>> alternatives;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    final groups = <List<String>>[keys, ...alternatives];
    return Wrap(spacing: ArcadeTokens.space4, runSpacing: ArcadeTokens.space4, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
      for (var g = 0; g < groups.length; g++) ...<Widget>[
        if (g > 0) Text('or', style: ArcadeTokens.textCaption.copyWith(color: c.muted)),
        for (final key in groups[g]) ArcadeKeyChip(key),
      ],
    ]);
  }
}

/// An inline notice with an optional action, in a tone.
class ArcadeNotice extends StatelessWidget {
  const ArcadeNotice(this.message, {super.key, this.tone = ArcadeTone.neutral, this.title, this.action});
  final String message;
  final String? title;
  final ArcadeTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    final t = _toneColours(c, tone);
    final icon = switch (tone) {
      ArcadeTone.ok => 'check',
      ArcadeTone.warn || ArcadeTone.danger => 'alert',
      _ => 'info',
    };
    final main = Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Padding(padding: const EdgeInsets.only(top: 2), child: ArcadeIcon(icon, color: t.fg)),
      const SizedBox(width: ArcadeTokens.space10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          if (title != null) Text(title!, style: ArcadeTokens.textBody.copyWith(color: c.text, fontWeight: FontWeight.w600)),
          Text(message, style: ArcadeTokens.textBody.copyWith(color: c.text)),
        ]),
      ),
    ]);
    return Semantics(
      liveRegion: tone == ArcadeTone.danger,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: ArcadeTokens.space12, vertical: ArcadeTokens.space10),
        decoration: BoxDecoration(color: t.bg, borderRadius: _radiusMd),
        child: action == null ? main : _TrailingLayout(main: main, trailing: action!),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(ArcadeTokens.radiusMd)).deflate(0.5));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 9) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) => oldDelegate.color != color;
}

/// The empty state: icon, heading, one sentence, actions, dashed border.
class ArcadeEmptyState extends StatelessWidget {
  const ArcadeEmptyState({super.key, required this.title, this.message, this.icon = 'info', this.actions = const <Widget>[]});
  final String title;
  final String? message;
  final String icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return CustomPaint(
      painter: _DashedBorderPainter(c.lineStrong),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ArcadeTokens.space24, vertical: ArcadeTokens.space32),
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          ArcadeGlyphTile(child: ArcadeIcon(icon, color: c.muted)),
          const SizedBox(height: ArcadeTokens.space12),
          Text(title, textAlign: TextAlign.center, style: ArcadeTokens.textHeading.copyWith(color: c.text)),
          if (message != null) ...<Widget>[
            const SizedBox(height: ArcadeTokens.space4),
            Text(message!, textAlign: TextAlign.center, style: ArcadeTokens.textBody.copyWith(color: c.muted)),
          ],
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: ArcadeTokens.space16),
            Wrap(spacing: ArcadeTokens.space8, runSpacing: ArcadeTokens.space8, alignment: WrapAlignment.center, children: actions),
          ],
        ]),
      ),
    );
  }
}

/// A toast (STANDARD.md §5): info and success close after 5 s, errors stay
/// until closed.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showArcadeToast(
  BuildContext context,
  String message, {
  ArcadeTone tone = ArcadeTone.neutral,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final c = arcadeColors(context);
  final error = tone == ArcadeTone.danger;
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  return messenger.showSnackBar(SnackBar(
    content: Row(children: <Widget>[
      if (tone != ArcadeTone.neutral) ...<Widget>[
        ArcadeIcon(tone == ArcadeTone.ok ? 'check' : error ? 'alert' : 'info', color: _toneColours(c, tone).fg),
        const SizedBox(width: ArcadeTokens.space8),
      ],
      Expanded(child: Text(message)),
    ]),
    duration: error ? const Duration(days: 1) : ArcadeTokens.toast,
    showCloseIcon: error,
    closeIconColor: c.muted,
    action: actionLabel == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}, textColor: c.accentInk),
  ));
}

/// A section: heading (+ meta) above a bordered list of rows.
class ArcadeListSection extends StatelessWidget {
  const ArcadeListSection({super.key, this.title, this.meta, required this.children, this.trailing});
  final String? title;
  final String? meta;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      if (title != null)
        Padding(
          padding: const EdgeInsets.only(bottom: ArcadeTokens.space10),
          child: Row(children: <Widget>[
            Expanded(child: Text(title!, style: ArcadeTokens.textHeading.copyWith(color: c.text))),
            if (meta != null) Text(meta!, style: ArcadeTokens.textSmall.copyWith(color: c.muted)),
            if (trailing != null) trailing!,
          ]),
        ),
      DecoratedBox(
        decoration: BoxDecoration(color: c.panel, borderRadius: _radiusMd, border: Border.all(color: c.line)),
        child: ClipRRect(
          borderRadius: _radiusMd,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            for (var i = 0; i < children.length; i++) ...<Widget>[
              if (i > 0) Divider(height: 1, thickness: 1, color: c.line),
              children[i],
            ],
          ]),
        ),
      ),
    ]);
  }
}

/// A list row: leading glyph, title and subtitle, trailing control, and
/// optional [extra] content below. Clickable rows get a hover fill; a
/// [selected] row uses `accent-soft`.
class ArcadeRow extends StatelessWidget {
  const ArcadeRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.extra,
    this.onTap,
    this.selected = false,
    this.minHeight = ArcadeTokens.row,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 2,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? extra;
  final VoidCallback? onTap;
  final bool selected;
  final double minHeight;
  final int titleMaxLines;
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    final main = Row(children: <Widget>[
      if (leading != null) ...<Widget>[leading!, const SizedBox(width: ArcadeTokens.space12)],
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: <Widget>[
          Text(title,
              maxLines: titleMaxLines,
              overflow: TextOverflow.ellipsis,
              style: ArcadeTokens.textBody.copyWith(color: c.text, fontWeight: FontWeight.w500)),
          if (subtitle != null)
            Text(subtitle!, maxLines: subtitleMaxLines, overflow: TextOverflow.ellipsis, style: ArcadeTokens.textSmall.copyWith(color: c.muted)),
        ]),
      ),
    ]);
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ArcadeTokens.space14, vertical: ArcadeTokens.space8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
          if (trailing == null) main else _TrailingLayout(main: main, trailing: trailing!),
          if (extra != null) Padding(padding: const EdgeInsets.only(top: ArcadeTokens.space10), child: extra),
        ]),
      ),
    );
    return Material(
      color: selected ? c.accentSoft : Colors.transparent,
      child: onTap == null ? content : InkWell(onTap: onTap, hoverColor: c.hover, child: content),
    );
  }
}

/// Lays out a row's (or notice's) main part and its trailing control: side by side when
/// the title keeps at least [_minTitle] px (or its whole width), otherwise
/// the trailing control goes under the title. Unlike a LayoutBuilder it
/// reports intrinsic sizes, so rows work inside dialogs.
class _TrailingLayout extends MultiChildRenderObjectWidget {
  _TrailingLayout({required Widget main, required Widget trailing}) : super(children: <Widget>[main, trailing]);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTrailingLayout();
}

class _TrailingParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderTrailingLayout extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _TrailingParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _TrailingParentData> {
  static const double _gap = ArcadeTokens.space12;
  static const double _stackGap = ArcadeTokens.space8;
  static const double _minTitle = 160;

  RenderBox get _main => firstChild!;
  RenderBox get _trailing => lastChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _TrailingParentData) child.parentData = _TrailingParentData();
  }

  bool _inline(double width) {
    if (!width.isFinite) return true;
    final title = _main.getMaxIntrinsicWidth(double.infinity);
    final trailing = _trailing.getMaxIntrinsicWidth(double.infinity);
    return trailing + _gap + (title < _minTitle ? title : _minTitle) <= width;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _main.getMinIntrinsicWidth(double.infinity) > _trailing.getMinIntrinsicWidth(double.infinity)
          ? _main.getMinIntrinsicWidth(double.infinity)
          : _trailing.getMinIntrinsicWidth(double.infinity);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _main.getMaxIntrinsicWidth(double.infinity) + _gap + _trailing.getMaxIntrinsicWidth(double.infinity);

  double _height(double width) {
    final trailingWidth = _trailing.getMaxIntrinsicWidth(double.infinity);
    if (_inline(width)) {
      final main = _main.getMinIntrinsicHeight(width.isFinite ? width - trailingWidth - _gap : double.infinity);
      final trailing = _trailing.getMinIntrinsicHeight(trailingWidth);
      return main > trailing ? main : trailing;
    }
    return _main.getMinIntrinsicHeight(width) + _stackGap + _trailing.getMinIntrinsicHeight(width);
  }

  @override
  double computeMinIntrinsicHeight(double width) => _height(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _height(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.maxWidth;
    Size measure(RenderBox child, BoxConstraints c) {
      if (dry) return child.getDryLayout(c);
      child.layout(c, parentUsesSize: true);
      return child.size;
    }

    if (_inline(width)) {
      final trailing = measure(_trailing, BoxConstraints(maxWidth: width.isFinite ? width : double.infinity));
      final mainWidth = width.isFinite ? width - trailing.width - _gap : _main.getMaxIntrinsicWidth(double.infinity);
      final main = measure(_main, BoxConstraints.tightFor(width: mainWidth < 0 ? 0 : mainWidth));
      final height = main.height > trailing.height ? main.height : trailing.height;
      if (!dry) {
        (_main.parentData! as _TrailingParentData).offset = Offset(0, (height - main.height) / 2);
        (_trailing.parentData! as _TrailingParentData).offset = Offset(mainWidth + _gap, (height - trailing.height) / 2);
      }
      return constraints.constrain(Size(mainWidth + _gap + trailing.width, height));
    }
    final main = measure(_main, BoxConstraints.tightFor(width: width));
    final trailing = measure(_trailing, BoxConstraints(maxWidth: width));
    if (!dry) {
      (_main.parentData! as _TrailingParentData).offset = Offset.zero;
      (_trailing.parentData! as _TrailingParentData).offset = Offset(0, main.height + _stackGap);
    }
    return constraints.constrain(Size(width, main.height + _stackGap + trailing.height));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);
}

/// A settings row with a switch on the right; the whole row toggles it.
class ArcadeSwitchRow extends StatelessWidget {
  const ArcadeSwitchRow({super.key, required this.title, this.subtitle, required this.value, required this.onChanged});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: ArcadeRow(
        title: title,
        subtitle: subtitle,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: Switch(value: value, onChanged: onChanged),
      ),
    );
  }
}

/// A segmented control for up to four short options, each with an optional
/// count.
class ArcadeSegmented<T> extends StatelessWidget {
  const ArcadeSegmented({super.key, required this.options, required this.value, required this.onChanged, this.counts = const {}});
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T>? onChanged;
  final Map<T, int> counts;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Container(
      padding: const EdgeInsets.all(ArcadeTokens.space2),
      decoration: BoxDecoration(color: c.sunken, borderRadius: _radiusSm),
      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        for (final (option, label) in options)
          Semantics(
            selected: option == value,
            button: true,
            child: InkWell(
              onTap: onChanged == null ? null : () => onChanged!(option),
              borderRadius: const BorderRadius.all(Radius.circular(ArcadeTokens.radiusXs)),
              hoverColor: c.hover,
              child: AnimatedContainer(
                duration: ArcadeTokens.fast,
                height: ArcadeTokens.controlSm,
                padding: const EdgeInsets.symmetric(horizontal: ArcadeTokens.space10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: option == value ? c.panel : Colors.transparent,
                  borderRadius: const BorderRadius.all(Radius.circular(ArcadeTokens.radiusXs)),
                  border: option == value ? Border.all(color: c.line) : null,
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                  Text(label, style: ArcadeTokens.textControl.copyWith(color: option == value ? c.text : c.muted)),
                  if (counts[option] != null) ...<Widget>[
                    const SizedBox(width: ArcadeTokens.space6),
                    Text('${counts[option]}', style: ArcadeTokens.textCaption.copyWith(color: c.muted)),
                  ],
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// The search field: leading icon, clear button; Esc clears first, then
/// calls [onEscape] (close or leave).
class ArcadeSearchField extends StatefulWidget {
  const ArcadeSearchField({
    super.key,
    required this.controller,
    this.hint = 'Search',
    this.onChanged,
    this.onSubmitted,
    this.onEscape,
    this.focusNode,
    this.autofocus = false,
    this.height = ArcadeTokens.search,
    this.leading,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEscape;
  final FocusNode? focusNode;
  final bool autofocus;
  final double height;
  final Widget? leading;

  @override
  State<ArcadeSearchField> createState() => _ArcadeSearchFieldState();
}

class _ArcadeSearchFieldState extends State<ArcadeSearchField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(ArcadeSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  void _clear() {
    widget.controller.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (widget.controller.text.isNotEmpty) {
            _clear();
          } else {
            widget.onEscape?.call();
          }
        },
      },
      child: SizedBox(
        height: widget.height,
        child: TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          textAlignVertical: TextAlignVertical.center,
          style: ArcadeTokens.textBody.copyWith(color: c.text),
          decoration: InputDecoration(
            hintText: widget.hint,
            contentPadding: EdgeInsets.zero,
            prefixIcon: widget.leading ?? Padding(padding: const EdgeInsets.all(ArcadeTokens.space10), child: ArcadeIcon('search', color: c.muted)),
            prefixIconConstraints: BoxConstraints.tight(Size.square(widget.height)),
            suffixIcon: widget.controller.text.isEmpty
                ? null
                : ArcadeButton(label: 'Clear search', icon: 'x', iconOnly: true, small: true, variant: ArcadeButtonVariant.ghost, onPressed: _clear),
            suffixIconConstraints: BoxConstraints.tight(Size.square(widget.height)),
          ),
        ),
      ),
    );
  }
}

/// The page head: title, one-line subtitle, actions on the right.
class ArcadePageHead extends StatelessWidget {
  const ArcadePageHead({super.key, required this.title, this.subtitle, this.actions = const <Widget>[]});
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Semantics(header: true, child: Text(title, style: ArcadeTokens.textTitle.copyWith(color: c.text))),
      if (subtitle != null) ...<Widget>[
        const SizedBox(height: ArcadeTokens.space4),
        Text(subtitle!, style: ArcadeTokens.textBody.copyWith(color: c.muted)),
      ],
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: ArcadeTokens.space24),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.end,
        runSpacing: ArcadeTokens.space12,
        spacing: ArcadeTokens.space16,
        children: <Widget>[
          text,
          if (actions.isNotEmpty) Wrap(spacing: ArcadeTokens.space8, runSpacing: ArcadeTokens.space8, children: actions),
        ],
      ),
    );
  }
}

/// One sidebar tab: icon, label, optional count. Collapsed shows the icon
/// only, with the label as tooltip.
class ArcadeNavItem extends StatelessWidget {
  const ArcadeNavItem({super.key, required this.icon, required this.label, required this.selected, required this.onTap, this.count, this.collapsed = false});
  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    final item = Semantics(
      selected: selected,
      button: true,
      label: collapsed ? label : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: _radiusSm,
        hoverColor: c.hover,
        child: Container(
          height: ArcadeTokens.nav,
          padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : ArcadeTokens.space10),
          alignment: collapsed ? Alignment.center : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: selected ? c.panel : Colors.transparent,
            borderRadius: _radiusSm,
            border: selected ? Border.all(color: c.line) : null,
          ),
          child: collapsed
              ? ArcadeIcon(icon, color: selected ? c.accentInk : c.muted)
              : Row(children: <Widget>[
                  ArcadeIcon(icon, color: selected ? c.accentInk : c.muted),
                  const SizedBox(width: ArcadeTokens.space10),
                  Expanded(
                    child: Text(label,
                        overflow: TextOverflow.ellipsis,
                        style: ArcadeTokens.textControl.copyWith(color: selected ? c.text : c.muted, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
                  ),
                  if (count != null) Text('$count', style: ArcadeTokens.textCaption.copyWith(color: c.muted)),
                ]),
        ),
      ),
    );
    return collapsed ? Tooltip(message: label, child: item) : item;
  }
}

/// The 212 px sidebar (64 px when [collapsed]): brand mark tile + app name,
/// nav items, then a footer slot and "Version x.y.z".
class ArcadeSidebar extends StatelessWidget {
  const ArcadeSidebar({
    super.key,
    required this.appName,
    required this.mark,
    required this.items,
    this.footer,
    this.version,
    this.collapsed = false,
  });

  final String appName;
  final Widget mark;
  final List<Widget> items;
  final Widget? footer;
  final String? version;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Container(
      width: collapsed ? ArcadeTokens.sidebarCollapsed : ArcadeTokens.sidebar,
      decoration: BoxDecoration(color: c.bg, border: Border(right: BorderSide(color: c.line))),
      padding: EdgeInsets.symmetric(horizontal: collapsed ? ArcadeTokens.space12 : ArcadeTokens.space14, vertical: ArcadeTokens.space16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Row(mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start, children: <Widget>[
          Container(
            width: ArcadeTokens.tileSm,
            height: ArcadeTokens.tileSm,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.accent, borderRadius: const BorderRadius.all(Radius.circular(ArcadeTokens.radiusTileSm))),
            child: IconTheme.merge(data: IconThemeData(color: c.accentText), child: mark),
          ),
          if (!collapsed) ...<Widget>[
            const SizedBox(width: ArcadeTokens.space10),
            Expanded(child: Text(appName, overflow: TextOverflow.ellipsis, style: ArcadeTokens.textHeading.copyWith(color: c.text))),
          ],
        ]),
        const SizedBox(height: ArcadeTokens.space20),
        Expanded(
          child: ListView.separated(
            itemCount: items.length,
            separatorBuilder: (context, index) => const SizedBox(height: ArcadeTokens.space2),
            itemBuilder: (context, index) => items[index],
          ),
        ),
        if (footer != null) ...<Widget>[Divider(color: c.line), const SizedBox(height: ArcadeTokens.space8), footer!],
        if (version != null && !collapsed) ...<Widget>[
          const SizedBox(height: ArcadeTokens.space8),
          Text('Version $version', style: ArcadeTokens.textCaption.copyWith(color: c.muted)),
        ],
      ]),
    );
  }
}

/// An overlay row (Template B): 40 px, or 52 px with a subtitle. Selected =
/// `accent-soft` fill plus a 2 px accent bar.
class ArcadeOverlayRow extends StatelessWidget {
  const ArcadeOverlayRow({super.key, required this.title, this.subtitle, this.leading, this.trailing, this.selected = false, this.onTap, this.onHover});
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onHover;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Semantics(
      selected: selected,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        onHover: onHover,
        borderRadius: _radiusSm,
        hoverColor: c.hover,
        child: Container(
          height: subtitle == null ? ArcadeTokens.rowOverlay : ArcadeTokens.rowOverlay2,
          decoration: BoxDecoration(color: selected ? c.accentSoft : Colors.transparent, borderRadius: _radiusSm),
          child: Row(children: <Widget>[
            Container(width: ArcadeTokens.selectionBar, height: double.infinity, color: selected ? c.accent : Colors.transparent),
            const SizedBox(width: ArcadeTokens.space10),
            if (leading != null) ...<Widget>[leading!, const SizedBox(width: ArcadeTokens.space10)],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ArcadeTokens.textBody.copyWith(color: c.text, fontWeight: FontWeight.w500)),
                if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: ArcadeTokens.textSmall.copyWith(color: c.muted)),
              ]),
            ),
            if (trailing != null) ...<Widget>[const SizedBox(width: ArcadeTokens.space8), trailing!],
            const SizedBox(width: ArcadeTokens.space10),
          ]),
        ),
      ),
    );
  }
}

/// The overlay footer hint bar: 28 px of key chips and labels.
class ArcadeHintBar extends StatelessWidget {
  const ArcadeHintBar(this.hints, {super.key});

  /// (keys, label), e.g. (['↵'], 'Paste').
  final List<(List<String>, String)> hints;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    return Container(
      height: ArcadeTokens.hintBar + ArcadeTokens.space8,
      padding: const EdgeInsets.symmetric(horizontal: ArcadeTokens.space12),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
      child: Row(children: <Widget>[
        for (var i = 0; i < hints.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: ArcadeTokens.space14),
          ArcadeKeyCombo(hints[i].$1),
          const SizedBox(width: ArcadeTokens.space6),
          // Weighted by length: equal shares cut a long label while short
          // ones leave space unused.
          Flexible(
            flex: hints[i].$2.length.clamp(1, 1000).toInt(),
            child: Text(hints[i].$2, overflow: TextOverflow.ellipsis, style: ArcadeTokens.textCaption.copyWith(color: c.muted)),
          ),
        ],
      ]),
    );
  }
}

/// The kit dialog: title, body, actions right-aligned with the primary last.
/// Esc and the backdrop close it unless [barrierDismissible] is false.
Future<T?> showArcadeDialog<T>({
  required BuildContext context,
  required String title,
  required Widget body,
  required List<Widget> Function(BuildContext context) actions,
  bool barrierDismissible = true,
  double maxWidth = 440,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: body),
      actionsAlignment: MainAxisAlignment.end,
      actionsPadding: const EdgeInsets.fromLTRB(ArcadeTokens.space20, 0, ArcadeTokens.space20, ArcadeTokens.space20),
      actions: <Widget>[
        Wrap(spacing: ArcadeTokens.space8, runSpacing: ArcadeTokens.space8, alignment: WrapAlignment.end, children: actions(context)),
      ],
    ),
  );
}

/// Confirm before destroying (STANDARD.md §5.1): names the thing, one
/// sentence on what is lost, "Keep" / the destructive verb. True when confirmed.
Future<bool> confirmArcadeDestroy(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String keepLabel = 'Keep',
}) async {
  final confirmed = await showArcadeDialog<bool>(
    context: context,
    title: title,
    body: Text(message),
    barrierDismissible: false,
    actions: (dialog) => <Widget>[
      ArcadeButton(label: keepLabel, autofocus: true, onPressed: () => Navigator.of(dialog).pop(false)),
      ArcadeButton(label: confirmLabel, variant: ArcadeButtonVariant.destructive, onPressed: () => Navigator.of(dialog).pop(true)),
    ],
  );
  return confirmed ?? false;
}

/// A loading placeholder row (static; no shimmer).
class ArcadeSkeletonRow extends StatelessWidget {
  const ArcadeSkeletonRow({super.key, this.height = ArcadeTokens.row});
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = arcadeColors(context);
    Widget bar(double width) => Container(width: width, height: 10, decoration: BoxDecoration(color: c.sunken, borderRadius: _radiusSm));
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ArcadeTokens.space14),
        child: Row(children: <Widget>[
          Container(width: ArcadeTokens.tile, height: ArcadeTokens.tile, decoration: BoxDecoration(color: c.sunken, borderRadius: _radiusTile)),
          const SizedBox(width: ArcadeTokens.space12),
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[bar(160), const SizedBox(height: ArcadeTokens.space6), bar(96)])),
        ]),
      ),
    );
  }
}
