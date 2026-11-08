import 'package:flutter/material.dart';

import 'theme.dart';

const _palettes = [
  [Color(0xFF3C7BFF), Color(0xFF7A5CFF)],
  [Color(0xFFFF7A59), Color(0xFFE5436F)],
  [Color(0xFF20C9A6), Color(0xFF1F8FD6)],
  [Color(0xFFF7B733), Color(0xFFFC5C4C)],
  [Color(0xFFB45CFF), Color(0xFF5C6CFF)],
  [Color(0xFF39D6D0), Color(0xFF3C7BFF)],
  [Color(0xFFFF6FB5), Color(0xFF9B5CFF)],
];

/// Generated avatar: colour comes from the stable id, so a person keeps it everywhere.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.id,
    required this.name,
    this.size = 48,
    this.group = false,
    this.icon,
  });
  final String id;
  final String name;
  final double size;
  final bool group;

  /// Shown instead of initials, for a chat with no person behind it.
  final IconData? icon;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = String.fromCharCode(parts.first.runes.first);
    if (parts.length == 1) return first.toUpperCase();
    return (first + String.fromCharCode(parts.last.runes.first)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // Not hashCode: that can differ between runs, and the colour has to stay put.
    final p = _palettes[id.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0xFFFFFF) % _palettes.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: p),
      ),
      alignment: Alignment.center,
      child: icon != null
          ? Icon(icon, color: Colors.white, size: size * 0.56)
          : group
          ? Icon(Icons.groups_rounded, color: Colors.white, size: size * 0.56)
          : Text(
              _initials,
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.36),
            ),
    );
  }
}

/// Blue ring marks unseen stories, as in the Home screen's story row.
class StoryRing extends StatelessWidget {
  const StoryRing({super.key, required this.child, required this.size, this.unseen = true});
  final Widget child;
  final double size;
  final bool unseen;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: unseen ? SyncColors.accent : Colors.white24, width: 2.5),
      ),
      child: child,
    );
  }
}

class OnlineDot extends StatelessWidget {
  const OnlineDot({super.key, this.size = 12});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: SyncColors.online,
      shape: BoxShape.circle,
      border: Border.all(color: SyncColors.bgMid, width: 2),
    ),
  );
}
