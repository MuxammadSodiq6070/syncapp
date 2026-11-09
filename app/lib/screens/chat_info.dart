import 'package:flutter/material.dart';

import '../core/localization.dart';
import '../core/models.dart';
import '../ui/avatar.dart';
import '../ui/format.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';
import 'people.dart';

class ChatInfoScreen extends StatelessWidget {
  const ChatInfoScreen({super.key, required this.chatId});
  final String chatId;

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final chat = state.chat(chatId);
        if (chat == null) return GlassPage(title: tr('details'), child: const SizedBox.shrink());
        return GlassPage(
          title: chat.isGroup ? 'Group details' : 'Details',
          child: ListView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: chat.isSaved || chat.isService
                ? _own(context, chat)
                : chat.isGroup
                ? _group(context, chat)
                : _direct(context, chat),
          ),
        );
      },
    );
  }

  Widget _hero(Chat chat, String subtitle) => Column(
    children: [
      Avatar(id: chat.avatarId, name: chat.title, size: 96, group: chat.isGroup, icon: chat.icon),
      const SizedBox(height: 10),
      Text(chat.title, style: SyncText.title, textAlign: TextAlign.center),
      const SizedBox(height: 4),
      Text(subtitle, style: SyncText.secondary, textAlign: TextAlign.center),
      const SizedBox(height: 20),
    ],
  );

  Widget _muteArchive(BuildContext context, Chat chat) {
    final state = context.sync;
    return GlassGroup(
      children: [
        GlassRow(
          icon: chat.muted ? Icons.notifications_outlined : Icons.notifications_off_outlined,
          title: chat.muted ? 'Unmute' : 'Mute',
          chevron: false,
          onTap: () => guarded(context, () => state.setFlag(chat.id, 'muted', !chat.muted)),
        ),
        GlassRow(
          icon: chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
          title: chat.archived ? 'Unarchive' : 'Archive',
          chevron: false,
          onTap: () => guarded(context, () => state.setFlag(chat.id, 'archived', !chat.archived)),
        ),
      ],
    );
  }

  /// Sync's own two chats. There is no person on the other side, so there is nobody
  /// to block, no username to show and no safety number to compare.
  List<Widget> _own(BuildContext context, Chat chat) => [
    _hero(chat, chat.isSaved ? tr('saved_subtitle') : tr('service_subtitle')),
    _muteArchive(context, chat),
  ];

  List<Widget> _direct(BuildContext context, Chat chat) {
    final state = context.sync;
    final peer = chat.peer!;
    final p = state.presence[peer.id];
    final status = p == null ? '@${peer.username}' : (p.online ? 'Active now' : lastSeenText(p.lastSeen));
    return [
      _hero(chat, status),
      _muteArchive(context, chat),
      const SizedBox(height: 16),
      GlassGroup(
        children: [
          GlassRow(
            icon: Icons.verified_user_outlined,
            title: tr('verify_encryption'),
            subtitle: trp('compare_safety', [peer.displayName]),
            onTap: () => _showSafety(context, peer),
          ),
        ],
      ),
      const SizedBox(height: 16),
      GlassGroup(
        children: [
          GlassRow(
            icon: Icons.block_rounded,
            title: peer.blocked ? 'Unblock' : 'Block',
            chevron: false,
            destructive: !peer.blocked,
            onTap: () async {
              if (!peer.blocked) {
                final yes = await confirmSheet(
                  context,
                  title: trp('block_person_q', [peer.displayName]),
                  body: "You won't receive their messages.",
                  action: 'Block',
                );
                if (!yes) return;
              }
              if (context.mounted) await guarded(context, () => state.setBlocked(peer.id, !peer.blocked));
            },
          ),
          _deleteRow(context, chat),
        ],
      ),
    ];
  }

  GlassRow _deleteRow(BuildContext context, Chat chat) {
    final state = context.sync;
    return GlassRow(
      icon: Icons.delete_outline_rounded,
      title: tr('delete_chat'),
      chevron: false,
      destructive: true,
      onTap: () async {
        final nav = Navigator.of(context);
        final yes = await confirmSheet(
          context,
          title: trp('delete_chat_q', [chat.title]),
          body: 'This removes the chat from this device only.',
          action: 'Delete',
        );
        if (!yes || !context.mounted) return;
        await guarded(context, () => state.deleteChat(chat.id));
        nav.popUntil((r) => r.isFirst);
      },
    );
  }

  List<Widget> _group(BuildContext context, Chat chat) {
    final state = context.sync;
    final isAdmin = chat.admin == state.me?.id;
    final others = chat.members.where((u) => u.id != state.me?.id);
    return [
      _hero(chat, '${chat.members.length} members'),
      _muteArchive(context, chat),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(tr('members'), style: SyncText.section),
      ),
      GlassGroup(
        children: [
          if (isAdmin && !chat.hasLeft) ...[
            GlassRow(
              icon: Icons.person_add_alt_outlined,
              title: tr('add_people'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddMembersScreen(chat: chat))),
            ),
            GlassRow(icon: Icons.edit_outlined, title: tr('rename_group'), onTap: () => _rename(context, chat)),
          ],
          for (final u in chat.members)
            GlassRow(
              leading: Avatar(id: u.id, name: u.displayName, size: 34),
              title: u.id == state.me?.id ? '${u.displayName} (you)' : u.displayName,
              subtitle: u.id == chat.admin ? 'Admin' : (u.username.isEmpty ? null : '@${u.username}'),
              chevron: false,
              onTap: isAdmin && u.id != state.me?.id ? () => _removeMember(context, chat, u, others) : null,
            ),
        ],
      ),
      const SizedBox(height: 16),
      GlassGroup(
        children: [
          if (!chat.hasLeft)
            GlassRow(
              icon: Icons.logout_rounded,
              title: tr('leave_group'),
              chevron: false,
              destructive: true,
              onTap: () async {
                final yes = await confirmSheet(context, title: trp('leave_group_q', [chat.title]), action: 'Leave');
                if (yes && context.mounted) await guarded(context, () => state.leaveGroup(chat.id));
              },
            ),
          _deleteRow(context, chat),
        ],
      ),
    ];
  }

  Future<void> _removeMember(BuildContext context, Chat chat, SyncUser u, Iterable<SyncUser> others) async {
    final state = context.sync;
    final yes = await confirmSheet(context, title: trp('remove_person_q', [u.displayName]), action: 'Remove');
    if (yes && context.mounted) {
      await guarded(
        context,
        () => state.updateGroup(chat.id, members: others.where((x) => x.id != u.id).map((x) => x.id).toList()),
      );
    }
  }

  void _rename(BuildContext context, Chat chat) {
    final state = context.sync;
    final c = TextEditingController(text: chat.title);
    showGlassSheet<void>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('rename_group'), style: SyncText.headline, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            GlassField(controller: c, autofocus: true),
            const SizedBox(height: 12),
            GlassButton(
              label: tr('save'),
              primary: true,
              onTap: () {
                Navigator.pop(ctx);
                if (c.text.trim().isNotEmpty) guarded(context, () => state.updateGroup(chat.id, title: c.text.trim()));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSafety(BuildContext context, SyncUser peer) async {
    final state = context.sync;
    await guarded(context, () async {
      final number = await state.safetyNumber(peer.id);
      if (!context.mounted) return;
      await showGlassSheet<void>(
        context,
        (ctx) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified_user_outlined, color: Colors.white, size: 34),
              const SizedBox(height: 10),
              Text(tr('safety_number'), style: SyncText.headline),
              const SizedBox(height: 12),
              SelectableText(
                number,
                textAlign: TextAlign.center,
                style: SyncText.body.copyWith(fontSize: 18, height: 1.6, letterSpacing: 1),
              ),
              const SizedBox(height: 12),
              Text(
                'If ${peer.displayName} sees the same number, nobody is intercepting your chat. Compare in person or on a call.',
                style: SyncText.secondary,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    });
  }
}
