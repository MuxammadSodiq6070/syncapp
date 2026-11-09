import 'package:flutter/material.dart';

import '../core/localization.dart';
import '../ui/avatar.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';
import 'ai.dart';
import 'chats_tab.dart';
import 'lists.dart';
import 'market.dart';
import 'people.dart';
import 'settings.dart';

class MenuTab extends StatelessWidget {
  const MenuTab({super.key});

  void _go(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    final media = MediaQuery.of(context).padding;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final me = state.me;
        final groups = state.groups;
        return ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: EdgeInsets.fromLTRB(16, media.top + 10, 16, media.bottom + 92),
          children: [
            Text(tr('menu'), style: SyncText.largeTitle),
            const SizedBox(height: 12),
            GlassGroup(
              children: [
                GlassRow(
                  leading: Avatar(id: me?.id ?? '', name: me?.displayName ?? '', size: 36),
                  title: me?.displayName ?? '',
                  subtitle: trp('edit_profile_at', [me?.username ?? '']),
                  chevron: false,
                  onTap: () => _go(context, const EditProfileScreen()),
                ),
                GlassRow(
                  icon: Icons.settings_outlined,
                  title: tr('settings'),
                  onTap: () => _go(context, const SettingsScreen()),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GlassGroup(
              children: [
                GlassRow(
                  icon: Icons.card_giftcard_rounded,
                  title: tr('marketplace'),
                  subtitle: tr('under_construction'),
                  onTap: () => _go(context, const MarketplaceScreen()),
                ),
                GlassRow(
                  icon: Icons.chat_outlined,
                  title: tr('message_requests'),
                  trailing: _Count(state.requests.length),
                  onTap: () => _go(context, const RequestsScreen()),
                ),
                GlassRow(
                  icon: Icons.archive_outlined,
                  title: tr('archive'),
                  trailing: _Count(state.archivedChats.length),
                  onTap: () => _go(context, const ArchiveScreen()),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GlassGroup(
              children: [
                GlassRow(
                  icon: Icons.people_outline_rounded,
                  title: tr('friend_requests'),
                  trailing: _Count(state.friendRequests.length),
                  onTap: () => _go(context, const FriendRequestsScreen()),
                ),
                GlassRow(
                  icon: Icons.smart_toy_outlined,
                  title: tr('chat_with_ais'),
                  onTap: () => _go(context, const AiListScreen()),
                ),
                GlassRow(
                  icon: Icons.add_rounded,
                  title: tr('create_ai'),
                  onTap: () => _go(context, const CreateAiScreen()),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(tr('communities'), style: SyncText.section),
            ),
            GlassGroup(
              children: [
                GlassRow(
                  icon: Icons.add_rounded,
                  title: tr('create_community'),
                  onTap: () => _go(context, const NewGroupScreen(community: true)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(tr('your_groups'), style: SyncText.section),
            ),
            if (groups.isEmpty)
              GlassGroup(
                children: [
                  GlassRow(
                    icon: Icons.group_add_outlined,
                    title: tr('create_group'),
                    onTap: () => _go(context, const NewGroupScreen()),
                  ),
                ],
              )
            else
              GlassGroup(
                children: [
                  for (final g in groups)
                    GlassRow(
                      leading: Avatar(id: g.id, name: g.title, size: 34, group: true),
                      title: g.title,
                      onTap: () => openChat(context, g.id),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.count);
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text('$count', style: SyncText.secondary),
    );
  }
}
