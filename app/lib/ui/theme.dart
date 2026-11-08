import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Colours and type sampled from the Liquid Glass Figma screens.
abstract final class SyncColors {
  static const bgTop = Color(0xFF131A33);
  static const bgMid = Color(0xFF17264A);
  static const bgBottom = Color(0xFF173464);
  static const accent = Color(0xFF2F68F5);
  static const accentBright = Color(0xFF0A84FF);
  static const activeTab = Color(0xFF8DB9FF);
  static const danger = Color(0xFFE5343B);
  static const online = Color(0xFF34D27B);
  static const textSecondary = Color(0xB3FFFFFF);
  static const textTertiary = Color(0x80FFFFFF);
  static const bubbleIn = Color(0x38FFFFFF);
  static const divider = Color(0x1FFFFFFF);
}

const syncFont = 'Inter';

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: syncFont,
    scaffoldBackgroundColor: SyncColors.bgTop,
    colorScheme: const ColorScheme.dark(
      primary: SyncColors.accent,
      secondary: SyncColors.activeTab,
      surface: SyncColors.bgMid,
      error: SyncColors.danger,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Colors.white,
      selectionColor: Color(0x662F68F5),
      selectionHandleColor: SyncColors.accent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xF0263A66),
      contentTextStyle: const TextStyle(fontFamily: syncFont, color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
  return base;
}

abstract final class SyncText {
  static const largeTitle = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w700,
    color: Colors.white,
    letterSpacing: -0.3,
  );
  static const title = TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white);
  static const headline = TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white);
  static const body = TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Colors.white);
  static const secondary = TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: SyncColors.textSecondary);
  static const caption = TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: SyncColors.textSecondary);
  static const section = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: SyncColors.textSecondary);
}
