import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'theme.dart';

import '../core/localization.dart';

/// Shared springs. All motion in the app runs on these physics rather than on fixed
/// durations, so interrupted gestures keep their velocity at any refresh rate.
abstract final class SyncSprings {
  static const snappy = SpringDescription(mass: 1, stiffness: 420, damping: 30);
  static const bouncy = SpringDescription(mass: 1, stiffness: 300, damping: 20);
  static const gentle = SpringDescription(mass: 1, stiffness: 170, damping: 24);
}

class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-0.7, -1),
          end: Alignment(0.7, 1),
          colors: [SyncColors.bgTop, SyncColors.bgMid, SyncColors.bgBottom],
          stops: [0, 0.55, 1],
        ),
      ),
      child: child,
    );
  }
}

/// Frosted panel with a bright specular rim: the Liquid Glass material.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 20, this.blur = 22, this.tint = 0.13, this.padding});

  final Widget child;
  final double radius;
  final double blur;
  final double tint;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: CustomPaint(
            foregroundPainter: _RimPainter(radius),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: shape,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: tint + 0.07),
                    Colors.white.withValues(alpha: tint - 0.05 < 0 ? 0 : tint - 0.05),
                  ],
                ),
              ),
              child: padding == null ? child : Padding(padding: padding!, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _RimPainter extends CustomPainter {
  const _RimPainter(this.radius);
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x80FFFFFF), Color(0x1AFFFFFF), Color(0x14FFFFFF), Color(0x59FFFFFF)],
          stops: [0, 0.4, 0.65, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RimPainter old) => old.radius != radius;
}

/// Sinks a little on touch and springs back, keeping velocity if released mid-way.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.onTap, this.onLongPress, this.scale = 0.95});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: 1);

  void _to(double target) {
    _c.animateWith(SpringSimulation(SyncSprings.snappy, _c.value, target, _c.velocity));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _to(widget.scale),
      onTapUp: (_) => _to(1),
      onTapCancel: () => _to(1),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ScaleTransition(scale: _c, child: widget.child),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, this.onTap, this.size = 40, this.iconSize = 19, this.tooltip});
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: PressScale(
        onTap: onTap,
        scale: 0.88,
        child: SizedBox.square(
          dimension: size,
          child: Glass(
            radius: size / 2,
            child: Center(
              child: Icon(icon, color: Colors.white, size: iconSize),
            ),
          ),
        ),
      ),
    );
  }
}

class GlassBackButton extends StatelessWidget {
  const GlassBackButton({super.key});

  @override
  Widget build(BuildContext context) => GlassIconButton(
    icon: Icons.chevron_left_rounded,
    iconSize: 24,
    tooltip: tr('back'),
    onTap: () => Navigator.of(context).maybePop(),
  );
}

/// Grouped card from the Menu screen: rows separated by hairlines.
class GlassGroup extends StatelessWidget {
  const GlassGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(const Divider(height: 1, thickness: 1, indent: 58, endIndent: 16, color: SyncColors.divider));
      }
    }
    return Glass(
      radius: 20,
      tint: 0.1,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

class GlassRow extends StatelessWidget {
  const GlassRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.chevron = true,
    this.destructive = false,
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool chevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? const Color(0xFFFF6B70) : Colors.white;
    return PressScale(
      onTap: onTap,
      scale: 0.985,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            if (leading != null)
              leading!
            else if (icon != null)
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.white.withValues(alpha: 0.07),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
                ),
                child: Icon(icon, size: 20, color: color),
              ),
            if (leading != null || icon != null) const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: SyncText.body.copyWith(color: color),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: SyncText.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            ?trailing,
            if (chevron && onTap != null) const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 24),
          ],
        ),
      ),
    );
  }
}

class GlassField extends StatelessWidget {
  const GlassField({
    super.key,
    this.controller,
    this.hint,
    this.onChanged,
    this.onSubmitted,
    this.maxLines = 1,
    this.minLines,
    this.leading,
    this.autofocus = false,
    this.keyboardType,
    this.prefixText,
    this.obscure = false,
    this.trailing,
  });

  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final int? maxLines;
  final int? minLines;
  final Widget? leading;
  final bool autofocus;
  final TextInputType? keyboardType;
  final String? prefixText;
  final bool obscure;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 16,
      tint: 0.12,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: autofocus,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                maxLines: maxLines,
                minLines: minLines,
                obscureText: obscure,
                keyboardType: keyboardType,
                style: SyncText.body,
                decoration: InputDecoration(
                  hintText: hint,
                  prefixText: prefixText,
                  prefixStyle: SyncText.body.copyWith(color: SyncColors.textSecondary),
                  hintStyle: SyncText.body.copyWith(color: SyncColors.textSecondary, fontWeight: FontWeight.w400),
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );
  }
}

class GlassButton extends StatelessWidget {
  const GlassButton({super.key, required this.label, this.onTap, this.primary = false, this.busy = false, this.icon});
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool busy;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    final content = Center(
      child: busy
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[Icon(icon, size: 18, color: Colors.white), const SizedBox(width: 8)],
                  Flexible(
                    child: Text(
                      label,
                      style: SyncText.body.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
    );
    return Opacity(
      opacity: enabled || busy ? 1 : 0.45,
      child: PressScale(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          height: 48,
          child: primary
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: const LinearGradient(colors: [Color(0xFF3C7BFF), SyncColors.accent]),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                  ),
                  child: content,
                )
              : Glass(radius: 24, child: content),
        ),
      ),
    );
  }
}

/// The glowing ring from the design, used here as the entry point to Sync AI.
class SyncOrb extends StatefulWidget {
  const SyncOrb({super.key, this.size = 36, this.animate = true});
  final double size;
  final bool animate;

  @override
  State<SyncOrb> createState() => _SyncOrbState();
}

class _SyncOrbState extends State<SyncOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 6));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(size: Size.square(widget.size), painter: _OrbPainter(_c.value)),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  const _OrbPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final stroke = size.width * 0.16;
    final rect = Rect.fromCircle(center: c, radius: r);
    final colors = const [Color(0xFF2F8BFF), Color(0xFF8F5BFF), Color(0xFF39D6D0), Color(0xFF2F8BFF)];
    canvas.drawCircle(
      c,
      r - stroke / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..shader = SweepGradient(colors: colors, transform: GradientRotation(t * 2 * math.pi)).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t;
}

class FloatingOrbButton extends StatelessWidget {
  const FloatingOrbButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Sync AI',
      child: PressScale(
        onTap: onTap,
        scale: 0.88,
        child: const SizedBox.square(
          dimension: 44,
          child: Glass(radius: 22, child: Center(child: SyncOrb(size: 28))),
        ),
      ),
    );
  }
}

/// Screen scaffold for every secondary page, matching the chat header's controls.
class GlassPage extends StatelessWidget {
  const GlassPage({super.key, required this.title, required this.child, this.actions = const [], this.bottom});
  final String title;
  final Widget child;
  final List<Widget> actions;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    const GlassBackButton(),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(title, style: SyncText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
                  ],
                ),
              ),
              Expanded(child: child),
              ?bottom,
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action});
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 72,
              child: Glass(radius: 36, child: Icon(icon, color: Colors.white, size: 32)),
            ),
            const SizedBox(height: 16),
            Text(title, style: SyncText.headline, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(body!, style: SyncText.secondary, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

void showToast(BuildContext context, Object message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(content: Text(message.toString())));
}

/// Runs an action and shows its failure instead of dropping it.
Future<void> guarded(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) showToast(context, e);
  }
}

/// Bottom sheet in the glass material.
Future<T?> showGlassSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black38,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
        10,
        0,
        10,
        MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom + 10,
      ),
      child: Glass(radius: 26, blur: 34, tint: 0.16, child: builder(ctx)),
    ),
  );
}

Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  String? body,
  required String action,
  bool destructive = true,
}) async {
  final r = await showGlassSheet<bool>(
    context,
    (ctx) => Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: SyncText.headline, textAlign: TextAlign.center),
          if (body != null) ...[
            const SizedBox(height: 8),
            Text(body, style: SyncText.secondary, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 16),
          GlassButton(label: action, primary: !destructive, onTap: () => Navigator.pop(ctx, true)),
          const SizedBox(height: 8),
          GlassButton(label: tr('cancel'), onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    ),
  );
  return r ?? false;
}
