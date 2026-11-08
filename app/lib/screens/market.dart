import 'package:flutter/material.dart';

import '../core/localization.dart';
import '../ui/glass.dart';
import '../ui/theme.dart';

class MarketplaceScreen extends StatelessWidget {
  const MarketplaceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: tr('marketplace'),
      // Actions completely removed: nobody can post or sell anything!
      child: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
        children: [
          const SizedBox(height: 10),
          // Glowing Neon Glass Gift Icon
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFFFF9F0A).withValues(alpha: 0.25),
                    const Color(0xFFBF5AF2).withValues(alpha: 0.25),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(color: const Color(0xFFFF9F0A).withValues(alpha: 0.5), width: 2),
                boxShadow: [
                  BoxShadow(color: const Color(0xFFFF9F0A).withValues(alpha: 0.25), blurRadius: 28, spreadRadius: 4),
                ],
              ),
              child: const Icon(Icons.card_giftcard_rounded, size: 48, color: Color(0xFFFF9F0A)),
            ),
          ),
          const SizedBox(height: 20),
          Text(tr('gift_shop'), style: SyncText.largeTitle.copyWith(fontSize: 26), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          // Prominent Status Pill
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFF9F0A).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFFFF9F0A).withValues(alpha: 0.6)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: Color(0xFFFF9F0A), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    tr('under_construction'),
                    style: const TextStyle(
                      fontFamily: syncFont,
                      color: Color(0xFFFF9F0A),
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Glass(
            radius: 20,
            padding: const EdgeInsets.all(18),
            child: Text(
              tr('gift_shop_desc'),
              style: SyncText.secondary.copyWith(height: 1.55),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text('Kelgusi Imkoniyatlar', style: SyncText.section.copyWith(color: Colors.white70)),
          ),
          _FeatureCard(
            icon: Icons.redeem_rounded,
            iconColor: const Color(0xFFFF375F),
            title: tr('gift_feature_1_title'),
            description: tr('gift_feature_1_desc'),
          ),
          const SizedBox(height: 10),
          _FeatureCard(
            icon: Icons.star_rounded,
            iconColor: const Color(0xFFFFD60A),
            title: tr('gift_feature_2_title'),
            description: tr('gift_feature_2_desc'),
          ),
          const SizedBox(height: 10),
          _FeatureCard(
            icon: Icons.palette_outlined,
            iconColor: const Color(0xFF0A84FF),
            title: tr('gift_feature_3_title'),
            description: tr('gift_feature_3_desc'),
          ),
          const SizedBox(height: 24),
          // Security disclaimer
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                const Icon(Icons.shield_outlined, color: Colors.white38, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Foydalanuvchilar eʼlon yoki tovar joylashtirishi to‘liq cheklangan.',
                    style: SyncText.caption.copyWith(color: Colors.white38),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.icon, required this.iconColor, required this.title, required this.description});

  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 18,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: SyncText.headline.copyWith(fontSize: 15)),
                const SizedBox(height: 4),
                Text(description, style: SyncText.secondary.copyWith(fontSize: 13, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Kept for test compatibility: direct navigation removed from app UI.
class PostListingScreen extends StatelessWidget {
  const PostListingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: 'Post Listing',
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.block_rounded, color: Colors.white54, size: 48),
              const SizedBox(height: 14),
              Text(tr('under_construction'), style: SyncText.headline),
              const SizedBox(height: 8),
              const Text(
                'Eʼlon joylashtirish hozircha cheklangan.',
                style: SyncText.secondary,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
