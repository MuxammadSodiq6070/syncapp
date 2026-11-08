import 'package:flutter/material.dart';

import '../core/models.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';
import 'chats_tab.dart';
import 'people.dart';

class _ChatList extends StatelessWidget {
  const _ChatList({required this.chats, required this.empty});
  final List<Chat> chats;
  final Widget empty;

  @override
  Widget build(BuildContext context) {
    if (chats.isEmpty) return empty;
    return ListView.builder(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      itemCount: chats.length,
      itemBuilder: (context, i) => ChatTile(chat: chats[i]),
    );
  }
}

class ArchiveScreen extends StatelessWidget {
  const ArchiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => GlassPage(
        title: 'Archive',
        child: _ChatList(
          chats: state.archivedChats,
          empty: const EmptyState(
            icon: Icons.archive_outlined,
            title: 'Nothing archived',
            body: 'Press and hold a chat to archive it. It comes back when someone sends a new message.',
          ),
        ),
      ),
    );
  }
}

class RequestsScreen extends StatelessWidget {
  const RequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => GlassPage(
        title: 'Message requests',
        child: _ChatList(
          chats: state.requests,
          empty: const EmptyState(
            icon: Icons.mark_chat_unread_outlined,
            title: 'No message requests',
            body: "Messages and group invites from people you haven't accepted show up here.",
          ),
        ),
      ),
    );
  }
}

class FriendRequestsScreen extends StatelessWidget {
  const FriendRequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final people = state.friendRequests;
        return GlassPage(
          title: 'Friend requests',
          actions: [
            GlassIconButton(
              icon: Icons.person_add_alt_outlined,
              tooltip: 'Find people',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewChatScreen())),
            ),
          ],
          child: people.isEmpty
              ? EmptyState(
                  icon: Icons.people_outline_rounded,
                  title: 'No friend requests',
                  body: 'When someone new messages you, you can accept them here.',
                  action: SizedBox(
                    width: 200,
                    child: GlassButton(
                      label: 'Find people',
                      primary: true,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewChatScreen())),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                  children: [
                    for (final c in people)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Glass(
                          radius: 20,
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              UserTile(user: c.peer!, dense: true, onTap: () => openChat(context, c.id)),
                              if (c.lastMessage != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4, top: 4, bottom: 10),
                                  child: Text(
                                    c.lastMessage!.preview,
                                    style: SyncText.secondary,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              Row(
                                children: [
                                  Expanded(
                                    child: GlassButton(
                                      label: 'Delete',
                                      onTap: () => guarded(context, () => state.deleteChat(c.id)),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: GlassButton(
                                      label: 'Accept',
                                      primary: true,
                                      onTap: () => guarded(context, () async {
                                        await state.acceptRequest(c.id);
                                        await state.markRead(c.id);
                                      }),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}
