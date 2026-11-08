import 'package:flutter/material.dart';

import '../ui/glass.dart';
import '../ui/theme.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: 'Privacy Policy',
      child: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Glass(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.shield_outlined, color: SyncColors.accentBright, size: 28),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Your Privacy is Absolute',
                        style: TextStyle(
                          fontFamily: syncFont,
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                Text(
                  'Sync is designed with a strict cryptographic zero-knowledge architecture. '
                  'The relay server and third parties cannot read your messages, listen to your media, '
                  'or identify who you are.',
                  style: SyncText.secondary,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const GlassGroup(
            children: [
              _PolicySection(
                title: '1. No Phone Number or Email',
                body:
                    'Your identity is a cryptographic Ed25519 key pair generated on your device. '
                    'No telephone number, email address, real name, or government ID is ever collected.',
              ),
              _PolicySection(
                title: '2. End-to-End Encryption (E2EE)',
                body:
                    'All direct messages, group messages, and media files are encrypted on your device '
                    'using Monocypher (XChaCha20-Poly1305, X25519, and BLAKE2b) before leaving the app. '
                    'Only intended recipients possess the keys to decrypt them.',
              ),
              _PolicySection(
                title: '3. Device Permissions',
                body:
                    '• Camera: Used solely when you choose to take and send photos.\n'
                    '• Microphone: Used solely when you record voice notes.\n'
                    '• Notifications: Used to alert you of incoming messages.\n'
                    'No audio or visual data is recorded in the background.',
              ),
              _PolicySection(
                title: '4. Third-Party Tracking & Ads',
                body:
                    'Sync contains zero ads, zero trackers, zero analytics SDKs, and zero telemetry. '
                    'We never sell, rent, or share user data.',
              ),
              _PolicySection(
                title: '5. Data Deletion & Ownership',
                body:
                    'You retain 100% ownership of your cryptographic keys and data. '
                    'You can delete your account and wipe all stored keys, messages, and files at any time '
                    'under Settings > Delete Account.',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  const _PolicySection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: syncFont,
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(fontFamily: syncFont, color: SyncColors.textSecondary, fontSize: 13, height: 1.45),
          ),
        ],
      ),
    );
  }
}
