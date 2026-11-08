import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'glass.dart';
import 'theme.dart';

class NavItem {
  const NavItem(this.icon, this.label, {this.badge = 0});
  final IconData icon;
  final String label;
  final int badge;
}

/// The floating tab bar: a glass lens rides a spring between tabs and can
/// be dragged, keeping its velocity when released.
class LiquidNavBar extends StatefulWidget {
  const LiquidNavBar({super.key, required this.items, required this.index, required this.onChanged});
  final List<NavItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  State<LiquidNavBar> createState() => _LiquidNavBarState();
}

class _LiquidNavBarState extends State<LiquidNavBar> with TickerProviderStateMixin {
  late final AnimationController _pos = AnimationController.unbounded(vsync: this, value: widget.index.toDouble());
  late final AnimationController _lift = AnimationController.unbounded(vsync: this, value: 0);

  @override
  void didUpdateWidget(LiquidNavBar old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _settle(widget.index);
  }

  void _settle(int target) {
    _pos.animateWith(SpringSimulation(SyncSprings.bouncy, _pos.value, target.toDouble(), _pos.velocity));
    _lift.animateWith(SpringSimulation(SyncSprings.snappy, _lift.value, 0, _lift.velocity));
  }

  void _raise() => _lift.animateWith(SpringSimulation(SyncSprings.snappy, _lift.value, 1, _lift.velocity));

  @override
  void dispose() {
    _pos.dispose();
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: LayoutBuilder(
        builder: (context, c) {
          final tab = c.maxWidth / widget.items.length;
          int nearest() => _pos.value.round().clamp(0, widget.items.length - 1);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) {
              _pos.stop();
              _raise();
            },
            onHorizontalDragUpdate: (d) {
              final next = _pos.value + d.delta.dx / tab;
              _pos.value = next.clamp(-0.15, widget.items.length - 0.85);
            },
            onHorizontalDragEnd: (d) {
              final i = nearest();
              // Carry the finger's speed into the spring, in tabs per second.
              _pos.animateWith(
                SpringSimulation(SyncSprings.bouncy, _pos.value, i.toDouble(), d.velocity.pixelsPerSecond.dx / tab),
              );
              _lift.animateWith(SpringSimulation(SyncSprings.snappy, _lift.value, 0, _lift.velocity));
              if (i != widget.index) widget.onChanged(i);
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const Positioned.fill(child: Glass(radius: 32, tint: 0.11, child: SizedBox.expand())),
                AnimatedBuilder(
                  animation: Listenable.merge([_pos, _lift]),
                  builder: (context, _) {
                    final lift = _lift.value.clamp(0.0, 1.2);
                    final w = tab + 12 + 10 * lift;
                    final h = 72 + 8 * lift;
                    return Positioned(
                      left: _pos.value * tab + (tab - w) / 2,
                      top: (64 - h) / 2,
                      width: w,
                      height: h,
                      child: IgnorePointer(child: _Lens(radius: h / 2)),
                    );
                  },
                ),
                Positioned.fill(
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.items.length; i++)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (_) => _raise(),
                            onTapCancel: () => _settle(widget.index),
                            onTap: () {
                              if (i == widget.index) _settle(i);
                              widget.onChanged(i);
                            },
                            child: Semantics(
                              button: true,
                              selected: i == widget.index,
                              label: widget.items[i].label,
                              child: ExcludeSemantics(
                                child: _TabLabel(item: widget.items[i], active: i == widget.index),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.item, required this.active});
  final NavItem item;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? SyncColors.activeTab : Colors.white;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(item.icon, color: color, size: 23),
            if (item.badge > 0)
              Positioned(
                right: -9,
                top: -6,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 17),
                  height: 17,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: SyncColors.danger, borderRadius: BorderRadius.circular(9)),
                  child: Text(
                    '${item.badge > 99 ? '99+' : item.badge}',
                    style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          item.label,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _Lens extends StatelessWidget {
  const _Lens({required this.radius});
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.42), width: 1.2),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.04),
                Colors.white.withValues(alpha: 0.11),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
