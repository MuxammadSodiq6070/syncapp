import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/localization.dart';
import '../core/models.dart';
import '../ui/avatar.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';
import 'language.dart';
import 'privacy.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _go(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => GlassPage(
        title: tr('settings'),
        child: ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            GlassGroup(
              children: [
                GlassRow(
                  icon: Icons.person_outline_rounded,
                  title: tr('profile'),
                  subtitle: '@${state.me?.username ?? ''}',
                  onTap: () => _go(context, const EditProfileScreen()),
                ),
                GlassRow(
                  icon: Icons.language_rounded,
                  title: tr('language'),
                  subtitle: AppLocale.instance.isAuto
                      ? '${tr('language_auto')} (${AppLocale.instance.currentLanguageName})'
                      : AppLocale.instance.currentLanguageName,
                  onTap: () => _go(context, const LanguageSelectionScreen()),
                ),
                GlassRow(
                  icon: Icons.shield_rounded,
                  title: tr('two_factor_auth'),
                  subtitle: SyncScope.of(context).has2FA ? tr('enabled') : tr('disabled'),
                  onTap: () => _manage2FA(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GlassGroup(
              children: [
                GlassRow(
                  icon: Icons.key_outlined,
                  title: tr('recovery_key'),
                  subtitle: 'Restore your account on a new device',
                  onTap: () => _go(context, const RecoveryKeyScreen()),
                ),
                GlassRow(
                  icon: Icons.block_rounded,
                  title: tr('blocked_people'),
                  onTap: () => _go(context, const BlockedScreen()),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GlassGroup(
              children: [
                GlassRow(
                  icon: Icons.dns_outlined,
                  title: tr('server'),
                  subtitle: '${SyncScope.of(context).gateway}  ·  ${state.online ? 'Connected' : 'Not connected'}',
                  chevron: false,
                ),
                GlassRow(
                  icon: Icons.shield_outlined,
                  title: tr('privacy_policy'),
                  onTap: () => _go(context, const PrivacyPolicyScreen()),
                ),
                GlassRow(
                  icon: Icons.info_outline_rounded,
                  title: tr('about_sync'),
                  onTap: () => showLicensePage(context: context, applicationName: 'Sync', applicationVersion: '1.0.0'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GlassGroup(
              children: [
                GlassRow(
                  icon: Icons.delete_forever_rounded,
                  title: tr('delete_account'),
                  subtitle: 'Permanently erase all keys and data on this device',
                  destructive: true,
                  chevron: false,
                  onTap: () => _confirmDeleteAccount(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _manage2FA(BuildContext context) async {
    const storage = FlutterSecureStorage();
    final pass = await storage.read(key: 'sync_2fa_password');
    final hint = await storage.read(key: 'sync_2fa_hint');
    if (!context.mounted) return;

    final passController = TextEditingController(text: pass ?? '');
    final hintController = TextEditingController(text: hint ?? '');
    final bool hasPass = pass != null && pass.isNotEmpty;

    showGlassSheet<void>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.shield_rounded, color: Color(0xFFFF9F0A), size: 44),
              const SizedBox(height: 12),
              Text(tr('two_factor_auth'), style: SyncText.headline, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                hasPass ? '${tr('two_factor_auth')}: ${tr('active')}' : tr('two_factor_subtitle'),
                style: SyncText.secondary,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              GlassField(controller: passController, hint: tr('two_factor_password'), obscure: true),
              const SizedBox(height: 10),
              GlassField(controller: hintController, hint: tr('two_factor_hint')),
              const SizedBox(height: 18),
              GlassButton(
                label: tr('continue_btn'),
                primary: true,
                onTap: () async {
                  final scope = SyncScope.of(context);
                  final p = passController.text.trim();
                  final h = hintController.text.trim();
                  if (p.isNotEmpty && p.length < 4) {
                    showToast(context, tr('password_short'));
                    return;
                  }
                  if (p.isEmpty) {
                    await storage.delete(key: 'sync_2fa_password');
                    await storage.delete(key: 'sync_2fa_hint');
                  } else {
                    await storage.write(key: 'sync_2fa_password', value: p);
                    if (h.isNotEmpty) {
                      await storage.write(key: 'sync_2fa_hint', value: h);
                    } else {
                      await storage.delete(key: 'sync_2fa_hint');
                    }
                  }
                  await scope.onUpdate2FA?.call();
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) showToast(context, tr('settings'));
                },
              ),
              if (hasPass) ...[
                const SizedBox(height: 10),
                GlassButton(
                  label: tr('lock_app'),
                  onTap: () {
                    Navigator.pop(ctx);
                    SyncScope.of(context).onLockApp?.call();
                  },
                ),
                const SizedBox(height: 10),
                GlassButton(
                  label: tr('disabled'),
                  onTap: () async {
                    final scope = SyncScope.of(context);
                    await storage.delete(key: 'sync_2fa_password');
                    await storage.delete(key: 'sync_2fa_hint');
                    await scope.onUpdate2FA?.call();
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) showToast(context, tr('disabled'));
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context) {
    showGlassSheet<void>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.warning_amber_rounded, color: SyncColors.danger, size: 48),
            const SizedBox(height: 12),
            const Text('Delete Account', style: SyncText.headline, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              'This will permanently erase your cryptographic keys, all local chats, messages, and downloaded media from this device.\n\nThis action cannot be undone.',
              style: SyncText.secondary,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            GlassButton(
              label: 'Delete everything',
              primary: true,
              onTap: () async {
                Navigator.pop(ctx);
                final scope = SyncScope.of(context);
                await scope.onDeleteAccount?.call();
              },
            ),
            const SizedBox(height: 10),
            GlassButton(label: 'Cancel', onTap: () => Navigator.pop(ctx)),
          ],
        ),
      ),
    );
  }
}

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _name = TextEditingController(text: context.sync.me?.displayName);
  late final _username = TextEditingController(text: context.sync.me?.username);
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.sync;
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await state.setProfile(_username.text.trim().replaceFirst('@', ''), _name.text.trim());
      nav.pop();
    } catch (e) {
      if (mounted) {
        showToast(context, e);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.sync.me;
    return GlassPage(
      title: 'Profile',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Avatar(id: me?.id ?? '', name: _name.text, size: 96),
          ),
          const SizedBox(height: 22),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 6),
            child: Text('Name', style: SyncText.section),
          ),
          GlassField(controller: _name, onChanged: (_) => setState(() {})),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 6),
            child: Text('Username', style: SyncText.section),
          ),
          GlassField(controller: _username, prefixText: '@', onChanged: (_) => setState(() {})),
          const SizedBox(height: 22),
          GlassButton(
            label: 'Save',
            primary: true,
            busy: _busy,
            onTap: _name.text.trim().isNotEmpty && _username.text.trim().isNotEmpty ? _save : null,
          ),
        ],
      ),
    );
  }
}

class RecoveryKeyScreen extends StatefulWidget {
  const RecoveryKeyScreen({super.key});

  @override
  State<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends State<RecoveryKeyScreen> {
  String? _key;

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: 'Recovery key',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Icon(Icons.key_outlined, color: Colors.white, size: 40),
          const SizedBox(height: 14),
          const Text(
            'This key is your account. Anyone who has it can read new messages sent to you and write as you. Keep it somewhere private, and never send it to anyone.',
            style: SyncText.secondary,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Sync has no password reset: if you lose this device without the key, the account is gone. Messages on this device do not move with the key.',
            style: SyncText.secondary,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (_key == null)
            GlassButton(
              label: 'Show recovery key',
              primary: true,
              onTap: () => guarded(context, () async {
                final k = await context.sync.recoveryKey();
                if (mounted) setState(() => _key = k);
              }),
            )
          else ...[
            Glass(
              radius: 16,
              padding: const EdgeInsets.all(14),
              child: SelectableText(_key!, style: SyncText.body.copyWith(height: 1.5), textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            GlassButton(
              label: 'Copy',
              icon: Icons.copy_rounded,
              onTap: () {
                Clipboard.setData(ClipboardData(text: _key!));
                showToast(context, 'Copied. Clear your clipboard after saving it.');
              },
            ),
          ],
        ],
      ),
    );
  }
}

class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key});

  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  late Future<List<SyncUser>> _users = context.sync.blockedUsers();

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: 'Blocked people',
      child: FutureBuilder<List<SyncUser>>(
        future: _users,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
          if (snap.data!.isEmpty) {
            return const EmptyState(
              icon: Icons.block_rounded,
              title: 'No one is blocked',
              body: "Blocked people can't reach you here.",
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              GlassGroup(
                children: [
                  for (final u in snap.data!)
                    GlassRow(
                      leading: Avatar(id: u.id, name: u.displayName, size: 34),
                      title: u.displayName,
                      chevron: false,
                      trailing: TextButton(
                        onPressed: () => guarded(context, () async {
                          final state = context.sync;
                          await state.setBlocked(u.id, false);
                          if (mounted) setState(() => _users = state.blockedUsers());
                        }),
                        child: const Text('Unblock', style: TextStyle(color: SyncColors.activeTab)),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
