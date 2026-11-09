import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/localization.dart';
import '../core/models.dart';
import '../ui/avatar.dart';
import '../ui/format.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';

const storyColors = [
  [Color(0xFF3C7BFF), Color(0xFF7A5CFF)],
  [Color(0xFFFF7A59), Color(0xFFE5436F)],
  [Color(0xFF20C9A6), Color(0xFF1F8FD6)],
  [Color(0xFF232F58), Color(0xFF3A5AA8)],
  [Color(0xFFB45CFF), Color(0xFFFF6FB5)],
];

List<Color> storyPalette(int i) => storyColors[i.abs() % storyColors.length];

void _openComposer(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StoryComposer()));

void openStories(BuildContext context, List<StoryGroup> groups, int index) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, a, _) => FadeTransition(
        opacity: a,
        child: StoryViewer(groups: groups, index: index),
      ),
    ),
  );
}

/// The row of story avatars with note bubbles at the top of Home.
class StoryRow extends StatelessWidget {
  const StoryRow({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    final me = state.me;
    final groups = state.storyGroups;
    final mine = state.myStories;
    return SizedBox(
      height: 142,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        children: [
          _StoryItem(
            label: mine == null ? 'Create story' : 'Your story',
            note: mine != null && mine.stories.last.isText ? mine.stories.last.text : 'Share a thought',
            ring: false,
            badge: mine == null,
            onTap: mine == null ? () => _openComposer(context) : () => openStories(context, [mine], 0),
            avatar: Avatar(id: me?.id ?? '', name: me?.displayName ?? '', size: 58),
          ),
          for (var i = 0; i < groups.length; i++)
            _StoryItem(
              label: groups[i].user.displayName.split(' ').first,
              note: groups[i].stories.last.isText ? groups[i].stories.last.text : groups[i].stories.last.caption,
              ring: !groups[i].allSeen,
              onTap: () => openStories(context, groups, i),
              avatar: Avatar(id: groups[i].user.id, name: groups[i].user.displayName, size: 58),
            ),
        ],
      ),
    );
  }
}

class _StoryItem extends StatelessWidget {
  const _StoryItem({
    required this.label,
    required this.note,
    required this.ring,
    required this.avatar,
    required this.onTap,
    this.badge = false,
  });
  final String label;
  final String note;
  final bool ring;
  final Widget avatar;
  final VoidCallback onTap;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.93,
      child: SizedBox(
        width: 82,
        child: Column(
          children: [
            SizedBox(
              height: 36,
              child: note.isEmpty
                  ? null
                  : Align(
                      alignment: Alignment.bottomCenter,
                      child: Glass(
                        radius: 11,
                        tint: 0.16,
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        child: Text(
                          note,
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 2),
            Stack(
              clipBehavior: Clip.none,
              children: [
                StoryRing(
                  size: 68,
                  unseen: ring,
                  child: FittedBox(child: avatar),
                ),
                if (badge)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2B3557),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white38),
                      ),
                      child: const Icon(Icons.add_rounded, color: Colors.white, size: 17),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class StoriesTab extends StatelessWidget {
  const StoriesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    final media = MediaQuery.of(context).padding;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final groups = state.storyGroups;
        final mine = state.myStories;
        return CustomScrollView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, media.top + 10, 16, 14),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(child: Text(tr('stories'), style: SyncText.largeTitle)),
                    GlassIconButton(
                      icon: Icons.add_rounded,
                      iconSize: 24,
                      tooltip: tr('create_story'),
                      onTap: () => _openComposer(context),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.72,
                children: [
                  _CreateCard(onTap: () => _openComposer(context)),
                  if (mine != null)
                    _StoryCard(group: mine, title: tr('your_story'), onTap: () => openStories(context, [mine], 0)),
                  for (var i = 0; i < groups.length; i++)
                    _StoryCard(
                      group: groups[i],
                      title: groups[i].user.displayName,
                      onTap: () => openStories(context, groups, i),
                    ),
                ],
              ),
            ),
            if (groups.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(32, 28, 32, 0),
                  child: Text(
                    'Stories from your contacts appear here for 24 hours.',
                    style: SyncText.secondary,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: media.bottom + 90)),
          ],
        );
      },
    );
  }
}

class _CreateCard extends StatelessWidget {
  const _CreateCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      child: Glass(
        radius: 22,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 52,
                child: Glass(radius: 26, child: const Icon(Icons.add_rounded, color: Colors.white, size: 28)),
              ),
              const SizedBox(height: 10),
              Text(tr('create_story'), style: SyncText.body),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryCard extends StatelessWidget {
  const _StoryCard({required this.group, required this.title, required this.onTap});
  final StoryGroup group;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = group.stories.last;
    return PressScale(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _StoryBackground(story: s, cacheWidth: 500),
            if (s.isText)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    s.text,
                    style: SyncText.body,
                    textAlign: TextAlign.center,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
            ),
            Positioned(
              top: 10,
              left: 10,
              child: StoryRing(
                size: 44,
                unseen: !group.allSeen,
                child: FittedBox(
                  child: Avatar(id: group.user.id, name: group.user.displayName, size: 40),
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Text(title, style: SyncText.body, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryBackground extends StatelessWidget {
  const _StoryBackground({super.key, required this.story, this.cacheWidth});
  final Story story;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    final path = story.localPath;
    if (!story.isText && path != null && File(path).existsSync()) {
      return Image.file(File(path), fit: BoxFit.cover, cacheWidth: cacheWidth);
    }
    final colors = story.isText ? storyPalette(story.color) : const [Color(0xFF232F58), Color(0xFF3A5AA8)];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
      ),
    );
  }
}

class StoryViewer extends StatefulWidget {
  const StoryViewer({super.key, required this.groups, required this.index});
  final List<StoryGroup> groups;
  final int index;

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer> with SingleTickerProviderStateMixin {
  late int _group = widget.index;
  int _story = 0;
  late final AnimationController _progress = AnimationController(vsync: this, duration: const Duration(seconds: 6))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
  final _reply = TextEditingController();
  final _replyFocus = FocusNode();

  StoryGroup get _current => widget.groups[_group];
  Story get _s => _current.stories[_story];
  bool get _isMine => _current.user.id == context.sync.me?.id;

  @override
  void initState() {
    super.initState();
    _replyFocus.addListener(() {
      if (_replyFocus.hasFocus) {
        _progress.stop();
      } else {
        _progress.forward();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _show());
  }

  void _show() {
    if (!mounted) return;
    context.sync.markStorySeen(_s);
    _progress.forward(from: 0);
  }

  void _next() {
    if (_story + 1 < _current.stories.length) {
      setState(() => _story++);
    } else if (_group + 1 < widget.groups.length) {
      setState(() {
        _group++;
        _story = 0;
      });
    } else {
      Navigator.of(context).maybePop();
      return;
    }
    _show();
  }

  void _prev() {
    if (_story > 0) {
      setState(() => _story--);
    } else if (_group > 0) {
      setState(() {
        _group--;
        _story = 0;
      });
    }
    _show();
  }

  Future<void> _sendReply() async {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    final state = context.sync;
    final name = _current.user.id;
    _reply.clear();
    _replyFocus.unfocus();
    await guarded(context, () async {
      final chat = await state.openDirect(name);
      await state.sendText(chat.id, text);
      if (mounted) showToast(context, 'Reply sent');
    });
  }

  @override
  void dispose() {
    _progress.dispose();
    _reply.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onLongPressStart: (_) => _progress.stop(),
        onLongPressEnd: (_) => _progress.forward(),
        onTapUp: (d) {
          if (_replyFocus.hasFocus) {
            _replyFocus.unfocus();
          } else if (d.globalPosition.dx < MediaQuery.of(context).size.width / 3) {
            _prev();
          } else {
            _next();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _StoryBackground(key: ValueKey(s.id), story: s),
            if (s.isText)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(s.text, style: SyncText.title.copyWith(fontSize: 26), textAlign: TextAlign.center),
                ),
              ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        for (var i = 0; i < _current.stories.length; i++)
                          Expanded(
                            child: Container(
                              height: 3,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              clipBehavior: Clip.hardEdge,
                              decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(2)),
                              child: AnimatedBuilder(
                                animation: _progress,
                                builder: (context, _) => FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: i < _story ? 1 : (i == _story ? _progress.value : 0),
                                  child: const ColoredBox(color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Avatar(id: _current.user.id, name: _current.user.displayName, size: 38),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_isMine ? 'Your story' : _current.user.displayName, style: SyncText.body),
                              Text(shortTime(s.time), style: SyncText.caption),
                            ],
                          ),
                        ),
                        GlassIconButton(
                          icon: Icons.close_rounded,
                          tooltip: tr('close'),
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (!s.isText && s.caption.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(s.caption, style: SyncText.body, textAlign: TextAlign.center),
                    ),
                  if (!_isMine)
                    Padding(
                      padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + MediaQuery.of(context).viewInsets.bottom),
                      child: Row(
                        children: [
                          Expanded(
                            child: Glass(
                              radius: 22,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                                child: TextField(
                                  controller: _reply,
                                  focusNode: _replyFocus,
                                  style: SyncText.body,
                                  onSubmitted: (_) => _sendReply(),
                                  decoration: InputDecoration(
                                    hintText: 'Reply to ${_current.user.displayName}',
                                    hintStyle: SyncText.secondary,
                                    border: InputBorder.none,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GlassIconButton(icon: Icons.send_rounded, size: 46, tooltip: tr('send_reply'), onTap: _sendReply),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StoryComposer extends StatefulWidget {
  const StoryComposer({super.key});

  @override
  State<StoryComposer> createState() => _StoryComposerState();
}

class _StoryComposerState extends State<StoryComposer> {
  final _text = TextEditingController();
  int _color = 0;
  String? _photo;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    await guarded(context, () async {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2160);
      if (x != null && mounted) setState(() => _photo = x.path);
    });
  }

  Future<void> _post() async {
    final state = context.sync;
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      if (_photo != null) {
        await state.postPhotoStory(_photo!, _text.text.trim());
      } else {
        await state.postTextStory(_text.text.trim(), _color);
      }
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
    final colors = storyPalette(_color);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_photo != null)
            Image.file(File(_photo!), fit: BoxFit.cover)
          else
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const GlassBackButton(),
                      const Spacer(),
                      GlassIconButton(icon: Icons.image_outlined, tooltip: tr('choose_photo'), onTap: _pick),
                      if (_photo != null) ...[
                        const SizedBox(width: 8),
                        GlassIconButton(
                          icon: Icons.close_rounded,
                          tooltip: tr('remove_photo'),
                          onTap: () => setState(() => _photo = null),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: TextField(
                        controller: _text,
                        autofocus: _photo == null,
                        textAlign: TextAlign.center,
                        maxLines: null,
                        onChanged: (_) => setState(() {}),
                        style: SyncText.title.copyWith(fontSize: 26),
                        decoration: InputDecoration(
                          hintText: _photo == null ? 'Type a story' : 'Add a caption',
                          hintStyle: SyncText.title.copyWith(fontSize: 26, color: Colors.white54),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      if (_photo == null)
                        for (var i = 0; i < storyColors.length; i++)
                          Semantics(
                            button: true,
                            label: trp('background_n', ['${i + 1}']),
                            child: GestureDetector(
                              onTap: () => setState(() => _color = i),
                              child: Container(
                                width: 30,
                                height: 30,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(colors: storyColors[i]),
                                  border: Border.all(color: Colors.white, width: i == _color ? 2.5 : 1),
                                ),
                              ),
                            ),
                          ),
                      const Spacer(),
                      SizedBox(
                        width: 110,
                        child: GlassButton(
                          label: tr('share'),
                          primary: true,
                          busy: _busy,
                          onTap: _photo != null || _text.text.trim().isNotEmpty ? _post : null,
                        ),
                      ),
                    ],
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
