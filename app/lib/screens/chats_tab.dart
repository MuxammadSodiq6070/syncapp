import 'dart:async';

import 'package:flutter/material.dart';

import '../core/localization.dart';
import '../core/models.dart';
import '../ui/avatar.dart';
import '../ui/format.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';
import 'ai.dart';
import 'chat_screen.dart';
import 'people.dart';
import 'stories.dart';

void openChat(BuildContext context, String chatId) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
}

class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<Message> _hits = [];
  List<SyncUser> _people = [];

  String get _query => _search.text.trim();

  void _onSearch(String _) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final q = _query;
      if (q.length < 2) {
        if (mounted) {
          setState(() {
            _hits = [];
            _people = [];
          });
        }
        return;
      }
      final state = context.sync;
      final hits = await state.searchMessages(q);
      // People search needs the server; local results still show when offline.
      final people = await state.searchUsers(q).catchError((_) => <SyncUser>[]);
      if (mounted && q == _query) {
        setState(() {
          _hits = hits;
          _people = people;
        });
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    final top = MediaQuery.of(context).padding.top;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final q = _query.toLowerCase();
        final chats = q.isEmpty
            ? state.mainChats
            : [...state.mainChats, ...state.archivedChats].where((c) => c.title.toLowerCase().contains(q)).toList();
        return CustomScrollView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, top + 10, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Text('Sync', style: SyncText.largeTitle)),
                        if (SyncScope.of(context).has2FA) ...[
                          GlassIconButton(
                            icon: Icons.lock_outline_rounded,
                            tooltip: tr('lock_app'),
                            onTap: () => SyncScope.of(context).onLockApp?.call(),
                          ),
                          const SizedBox(width: 8),
                        ],
                        GlassIconButton(
                          icon: Icons.edit_outlined,
                          tooltip: tr('new_message'),
                          onTap: () =>
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewChatScreen())),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    GlassField(
                      controller: _search,
                      hint: tr('search'),
                      onChanged: _onSearch,
                      leading: GestureDetector(
                        onTap: () =>
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiListScreen())),
                        child: const SyncOrb(size: 18, animate: false),
                      ),
                    ),
                    if (!state.online) ...[const SizedBox(height: 10), _ConnectionBanner(state: state.connection)],
                  ],
                ),
              ),
            ),
            if (q.isEmpty) const SliverToBoxAdapter(child: StoryRow()),
            if (q.isNotEmpty) const SliverToBoxAdapter(child: SizedBox(height: 12)),
            if (q.isEmpty && chats.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 100),
                  child: EmptyState(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: tr('no_chats_yet'),
                    body: 'Find someone by username to start an encrypted conversation.',
                    action: SizedBox(
                      width: 200,
                      child: GlassButton(
                        label: tr('new_message'),
                        primary: true,
                        onTap: () =>
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewChatScreen())),
                      ),
                    ),
                  ),
                ),
              ),
            SliverList.builder(
              itemCount: chats.length,
              itemBuilder: (context, i) => ChatTile(chat: chats[i]),
            ),
            if (q.isNotEmpty && _people.isNotEmpty) ...[
              const _SearchHeader('People'),
              SliverList.builder(
                itemCount: _people.length,
                itemBuilder: (context, i) {
                  final u = _people[i];
                  return UserTile(
                    user: u,
                    onTap: () => guarded(context, () async {
                      final c = await state.openDirect(u.id);
                      if (context.mounted) openChat(context, c.id);
                    }),
                  );
                },
              ),
            ],
            if (q.isNotEmpty && _hits.isNotEmpty) ...[
              const _SearchHeader('Messages'),
              SliverList.builder(
                itemCount: _hits.length,
                itemBuilder: (context, i) {
                  final m = _hits[i];
                  final c = state.chat(m.chatId);
                  return PressScale(
                    scale: 0.98,
                    onTap: () => openChat(context, m.chatId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c?.title ?? 'Chat', style: SyncText.body),
                          const SizedBox(height: 2),
                          Text(m.preview, style: SyncText.secondary, maxLines: 2, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
            if (q.isNotEmpty && chats.isEmpty && _hits.isEmpty && _people.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(tr('no_results'), style: SyncText.secondary, textAlign: TextAlign.center),
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: MediaQuery.of(context).padding.bottom + 90)),
          ],
        );
      },
    );
  }
}

class _SearchHeader extends StatelessWidget {
  const _SearchHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(title, style: SyncText.section),
    ),
  );
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.state});
  final String state;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70)),
      const SizedBox(width: 8),
      Text(state == 'connecting' ? 'Connecting…' : 'Waiting for network…', style: SyncText.caption),
    ],
  );
}

class ChatTile extends StatelessWidget {
  const ChatTile({super.key, required this.chat});
  final Chat chat;

  void _actions(BuildContext context) {
    final state = context.sync;
    showGlassSheet<void>(
      context,
      (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          GlassRow(
            icon: chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
            title: chat.archived ? 'Unarchive' : 'Archive',
            chevron: false,
            onTap: () {
              Navigator.pop(ctx);
              guarded(context, () => state.setFlag(chat.id, 'archived', !chat.archived));
            },
          ),
          GlassRow(
            icon: chat.muted ? Icons.notifications_outlined : Icons.notifications_off_outlined,
            title: chat.muted ? 'Unmute' : 'Mute',
            chevron: false,
            onTap: () {
              Navigator.pop(ctx);
              guarded(context, () => state.setFlag(chat.id, 'muted', !chat.muted));
            },
          ),
          GlassRow(
            icon: Icons.delete_outline_rounded,
            title: tr('delete_chat'),
            chevron: false,
            destructive: true,
            onTap: () async {
              Navigator.pop(ctx);
              final yes = await confirmSheet(
                context,
                title: trp('delete_chat_q', [chat.title]),
                body: 'This removes the chat from this device only.',
                action: 'Delete',
              );
              if (yes && context.mounted) guarded(context, () => state.deleteChat(chat.id));
            },
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    final last = chat.lastMessage;
    final typing = state.typingIn(chat.id);
    final unread = chat.unread > 0;
    final peerOnline = chat.peer != null && (state.presence[chat.peer!.id]?.online ?? false);

    String preview = '';
    if (typing != null) {
      preview = 'typing…';
    } else if (last != null) {
      final prefix = chat.isGroup && !last.outgoing
          ? '${chat.members.where((u) => u.id == last.sender).map((u) => u.displayName).firstOrNull ?? 'Someone'}: '
          : (last.outgoing ? 'You: ' : '');
      preview = '$prefix${last.preview}';
    } else if (chat.hasLeft) {
      preview = "You're no longer in this group";
    } else {
      preview = chat.isGroup ? 'New group' : 'Say hi';
    }

    return PressScale(
      scale: 0.98,
      onTap: () => openChat(context, chat.id),
      onLongPress: () => _actions(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            Stack(
              children: [
                Avatar(id: chat.avatarId, name: chat.title, size: 54, group: chat.isGroup, icon: chat.icon),
                if (peerOnline) const Positioned(right: 1, bottom: 1, child: OnlineDot(size: 14)),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          chat.title,
                          style: SyncText.headline.copyWith(fontSize: 16),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Only Sync's own chat earns the mark, and it earns it from
                      // the core's reserved chat type, never from anything a peer
                      // or the gateway can put in a field.
                      if (chat.isVerified) ...[
                        const SizedBox(width: 5),
                        const Icon(Icons.verified_rounded, size: 16, color: SyncColors.accent),
                      ],
                      if (chat.muted) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.notifications_off_outlined, size: 15, color: SyncColors.textSecondary),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SyncText.secondary.copyWith(
                            color: unread ? Colors.white : SyncColors.textSecondary,
                            fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (last != null)
                        Text('  ·  ${shortTime(last.time)}', style: SyncText.secondary.copyWith(fontSize: 13)),
                    ],
                  ),
                ],
              ),
            ),
            if (unread) ...[
              const SizedBox(width: 10),
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(color: SyncColors.accent, shape: BoxShape.circle),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
