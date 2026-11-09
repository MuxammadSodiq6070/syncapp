import 'dart:async';

import 'package:flutter/material.dart';

import '../core/localization.dart';
import '../core/models.dart';
import '../ui/avatar.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';
import 'chat_screen.dart';

class UserTile extends StatelessWidget {
  const UserTile({super.key, required this.user, this.onTap, this.trailing, this.dense = false});
  final SyncUser user;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.98,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: dense ? 0 : 16, vertical: dense ? 2 : 7),
        child: Row(
          children: [
            Avatar(id: user.id, name: user.displayName, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.displayName, style: SyncText.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (user.username.isNotEmpty) Text('@${user.username}', style: SyncText.caption),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Username search shared by new chat, new group and add-members.
mixin _UserSearch<T extends StatefulWidget> on State<T> {
  final query = TextEditingController();
  Timer? _debounce;
  List<SyncUser> results = [];
  bool searching = false;
  String? searchError;

  void onQuery(String q) {
    _debounce?.cancel();
    setState(() {});
    final term = q.trim();
    if (term.length < 2) {
      setState(() {
        results = [];
        searchError = null;
        searching = false;
      });
      return;
    }
    setState(() => searching = true);
    _debounce = Timer(const Duration(milliseconds: 280), () async {
      try {
        final r = await context.sync.searchUsers(term);
        if (mounted && term == query.text.trim()) {
          setState(() {
            results = r;
            searchError = null;
            searching = false;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            searchError = e.toString();
            searching = false;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    query.dispose();
    super.dispose();
  }
}

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> with _UserSearch {
  Future<void> _open(SyncUser u) => guarded(context, () async {
    final c = await context.sync.openDirect(u.id);
    if (mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(chatId: c.id)));
    }
  });

  @override
  Widget build(BuildContext context) {
    final contacts = context.sync.contacts;
    final term = query.text.trim();
    return GlassPage(
      title: tr('new_message'),
      child: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: GlassField(
              controller: query,
              hint: tr('search_by_username'),
              autofocus: true,
              onChanged: onQuery,
              leading: const Icon(Icons.search_rounded, color: Colors.white70, size: 20),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassGroup(
              children: [
                GlassRow(
                  icon: Icons.group_add_outlined,
                  title: tr('new_group'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewGroupScreen())),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (searching)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
            ),
          if (searchError != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(searchError!, style: SyncText.secondary, textAlign: TextAlign.center),
            ),
          if (term.length >= 2 && !searching && searchError == null && results.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(trp('no_one_found', [term]), style: SyncText.secondary, textAlign: TextAlign.center),
            ),
          for (final u in results) UserTile(user: u, onTap: () => _open(u)),
          if (term.length < 2 && contacts.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(tr('contacts'), style: SyncText.section),
            ),
            for (final u in contacts) UserTile(user: u, onTap: () => _open(u)),
          ],
        ],
      ),
    );
  }
}

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key, this.community = false});
  final bool community;

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> with _UserSearch {
  final _title = TextEditingController();
  final Map<String, SyncUser> _picked = {};
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _toggle(SyncUser u) => setState(() {
    if (_picked.remove(u.id) == null) _picked[u.id] = u;
  });

  Future<void> _create() async {
    final state = context.sync;
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final c = await state.createGroup(_title.text.trim(), _picked.keys.toList());
      nav.pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(chatId: c.id)));
    } catch (e) {
      if (mounted) {
        showToast(context, e);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.sync.contacts;
    final term = query.text.trim();
    final list = term.length >= 2 ? results : contacts;
    final noun = widget.community ? 'community' : 'group';
    return GlassPage(
      title: widget.community ? 'Create community' : 'New group',
      bottom: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GlassButton(
            label: _picked.isEmpty ? 'Add at least one person' : 'Create $noun (${_picked.length + 1})',
            primary: true,
            busy: _busy,
            onTap: _picked.isNotEmpty && _title.text.trim().isNotEmpty ? _create : null,
          ),
        ),
      ),
      child: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.only(top: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassField(
              controller: _title,
              hint: widget.community ? 'Community name' : 'Group name',
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassField(
              controller: query,
              hint: tr('search_by_username'),
              onChanged: onQuery,
              leading: const Icon(Icons.search_rounded, color: Colors.white70, size: 20),
            ),
          ),
          const SizedBox(height: 8),
          if (_picked.isNotEmpty)
            SizedBox(
              height: 72,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  for (final u in _picked.values)
                    GestureDetector(
                      onTap: () => _toggle(u),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          children: [
                            Avatar(id: u.id, name: u.displayName, size: 40),
                            const SizedBox(height: 2),
                            SizedBox(
                              width: 56,
                              child: Text(
                                u.displayName,
                                style: SyncText.caption.copyWith(fontSize: 10),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (searchError != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(searchError!, style: SyncText.secondary, textAlign: TextAlign.center),
            ),
          for (final u in list)
            UserTile(
              user: u,
              onTap: () => _toggle(u),
              trailing: Icon(
                _picked.containsKey(u.id) ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: _picked.containsKey(u.id) ? SyncColors.accentBright : Colors.white38,
              ),
            ),
        ],
      ),
    );
  }
}

class AddMembersScreen extends StatefulWidget {
  const AddMembersScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<AddMembersScreen> createState() => _AddMembersScreenState();
}

class _AddMembersScreenState extends State<AddMembersScreen> with _UserSearch {
  final Set<String> _picked = {};

  Future<void> _save() async {
    final state = context.sync;
    final nav = Navigator.of(context);
    await guarded(context, () async {
      await state.updateGroup(widget.chat.id, members: [...widget.chat.members.map((u) => u.id), ..._picked]);
      nav.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.chat.members.map((u) => u.id).toSet();
    final term = query.text.trim();
    final list = (term.length >= 2 ? results : context.sync.contacts).where((u) => !existing.contains(u.id)).toList();
    return GlassPage(
      title: tr('add_people'),
      bottom: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GlassButton(label: trp('add_count', ['${_picked.length}']), primary: true, onTap: _picked.isEmpty ? null : _save),
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.only(top: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassField(controller: query, hint: tr('search_by_username'), onChanged: onQuery, autofocus: true),
          ),
          const SizedBox(height: 8),
          for (final u in list)
            UserTile(
              user: u,
              onTap: () => setState(() {
                if (!_picked.remove(u.id)) _picked.add(u.id);
              }),
              trailing: Icon(
                _picked.contains(u.id) ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: _picked.contains(u.id) ? SyncColors.accentBright : Colors.white38,
              ),
            ),
        ],
      ),
    );
  }
}
