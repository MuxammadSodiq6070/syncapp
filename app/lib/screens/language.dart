import 'package:flutter/material.dart';

import '../core/localization.dart';
import '../ui/glass.dart';
import '../ui/theme.dart';

class LanguageSelectionScreen extends StatefulWidget {
  const LanguageSelectionScreen({super.key});

  @override
  State<LanguageSelectionScreen> createState() => _LanguageSelectionScreenState();
}

class _LanguageSelectionScreenState extends State<LanguageSelectionScreen> {
  final _search = TextEditingController();
  List<AppLanguage> _filtered = allGoogleTranslateLanguages;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearch);
  }

  @override
  void dispose() {
    _search.removeListener(_onSearch);
    _search.dispose();
    super.dispose();
  }

  void _onSearch() {
    final q = _search.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filtered = allGoogleTranslateLanguages;
      } else {
        _filtered = allGoogleTranslateLanguages.where((l) {
          return l.englishName.toLowerCase().contains(q) ||
              l.nativeName.toLowerCase().contains(q) ||
              l.code.toLowerCase().contains(q);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final locale = AppLocale.instance;
    final fullySupported = _filtered.where((l) => l.isFullySupported).toList();
    final otherLanguages = _filtered.where((l) => !l.isFullySupported).toList();

    return ListenableBuilder(
      listenable: locale,
      builder: (context, _) => GlassPage(
        title: tr('language'),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: GlassField(
                controller: _search,
                hint: tr('search_language'),
                leading: const Icon(Icons.search_rounded, color: Colors.white70),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                children: [
                  // Auto-detect option
                  GlassGroup(
                    children: [
                      GlassRow(
                        icon: Icons.auto_awesome_rounded,
                        title: tr('language_auto'),
                        subtitle: '${tr('language_auto')} (${locale.currentLanguageName})',
                        chevron: false,
                        trailing: locale.isAuto
                            ? const Icon(Icons.check_circle_rounded, color: SyncColors.accentBright, size: 22)
                            : null,
                        onTap: () async {
                          await locale.setLanguage('auto');
                          if (context.mounted) Navigator.pop(context);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Fully Supported Languages Section
                  if (fullySupported.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.verified_rounded, color: SyncColors.accentBright, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            'To‘liq tarjima qilingan tillar (${fullySupported.length})',
                            style: SyncText.section.copyWith(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    GlassGroup(
                      children: [
                        for (final lang in fullySupported)
                          GlassRow(
                            leading: Text(lang.flag, style: const TextStyle(fontSize: 22)),
                            title: lang.nativeName,
                            subtitle: lang.englishName != lang.nativeName ? lang.englishName : lang.code.toUpperCase(),
                            chevron: false,
                            trailing: (!locale.isAuto && locale.resolvedCode == lang.code)
                                ? const Icon(Icons.check_circle_rounded, color: SyncColors.accentBright, size: 22)
                                : Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF30D158).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: const Color(0xFF30D158).withValues(alpha: 0.4)),
                                    ),
                                    child: const Text(
                                      '100%',
                                      style: TextStyle(
                                        fontFamily: syncFont,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF30D158),
                                      ),
                                    ),
                                  ),
                            onTap: () async {
                              await locale.setLanguage(lang.code);
                              if (context.mounted) Navigator.pop(context);
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Other Google Translate Languages Section
                  if (otherLanguages.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 4),
                      child: Text(
                        'Boshqa tillar (Google Translate) (${otherLanguages.length})',
                        style: SyncText.section.copyWith(color: Colors.white70),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        'Eslatma: Ushbu tillarda tarjimasi yo‘q bo‘limlar avtomatik ingliz tilida ko‘rsatiladi.',
                        style: SyncText.caption.copyWith(color: Colors.white38),
                      ),
                    ),
                    GlassGroup(
                      children: [
                        for (final lang in otherLanguages)
                          GlassRow(
                            leading: Text(lang.flag, style: const TextStyle(fontSize: 22)),
                            title: lang.nativeName,
                            subtitle: lang.englishName != lang.nativeName ? lang.englishName : lang.code.toUpperCase(),
                            chevron: false,
                            trailing: (!locale.isAuto && locale.resolvedCode == lang.code)
                                ? const Icon(Icons.check_circle_rounded, color: SyncColors.accentBright, size: 22)
                                : null,
                            onTap: () async {
                              await locale.setLanguage(lang.code);
                              if (context.mounted) Navigator.pop(context);
                            },
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
