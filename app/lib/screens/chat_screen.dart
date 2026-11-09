import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import 'dart:io';

import '../core/localization.dart';
import '../core/models.dart';
import '../ui/avatar.dart';
import '../ui/format.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';
import 'ai.dart';
import 'chat_info.dart';
import 'extras.dart';
import 'message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chatId});
  final String chatId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _attachKey = GlobalKey();
  Message? _replyTo;
  Message? _editing;
  DateTime _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loadingOlder = false;

  String get _chatId => widget.chatId;

  @override
  void initState() {
    super.initState();
    final state = context.sync;
    state.openChatId = _chatId;
    state.loadThread(_chatId);
    state.markRead(_chatId);
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (_loadingOlder || _scroll.position.extentAfter > 400) return;
    _loadingOlder = true;
    context.sync.loadThread(_chatId, older: true).whenComplete(() => _loadingOlder = false);
  }

  @override
  void deactivate() {
    final state = context.sync;
    if (state.openChatId == _chatId) state.openChatId = null;
    super.deactivate();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    setState(() {});
    final now = DateTime.now();
    if (_input.text.isNotEmpty && now.difference(_lastTyping).inSeconds >= 3) {
      _lastTyping = now;
      context.sync.setTyping(_chatId);
    }
  }

  Future<void> _send([String? override]) async {
    final text = (override ?? _input.text).trim();
    if (text.isEmpty) return;
    final state = context.sync;
    final editing = _editing, replyTo = _replyTo;
    if (override == null) _input.clear();
    setState(() {
      _editing = null;
      _replyTo = null;
    });
    await guarded(context, () async {
      if (editing != null) {
        await state.editMessage(editing.id, text);
      } else {
        await state.sendText(_chatId, text, replyTo: replyTo?.id);
      }
    });
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  void _startEdit(Message m) {
    setState(() {
      _editing = m;
      _replyTo = null;
      _input.text = m.text;
    });
    _focus.requestFocus();
  }

  void _startReply(Message m) {
    setState(() {
      _replyTo = m;
      _editing = null;
    });
    _focus.requestFocus();
  }

  Future<void> _openMenu() async {
    _focus.unfocus();
    final box = _attachKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(Offset.zero);
    final action = await Navigator.of(context).push<_Attach>(_AttachRoute(anchor: anchor));
    if (action == null || !mounted) return;
    await guarded(context, () => _runAttach(action));
  }

  Future<void> _runAttach(_Attach a) async {
    final state = context.sync;
    switch (a) {
      case _Attach.camera:
        await _sendPicked(ImageSource.camera);
      case _Attach.gallery:
        await _sendPicked(ImageSource.gallery);
      case _Attach.record:
        final path = await showVoiceRecorder(context);
        if (path != null) await state.sendMedia(_chatId, path, 'file', 'Voice message.m4a', 'audio/mp4');
      case _Attach.file:
        final f = (await FilePicker.pickFiles()).firstOrNull;
        if (f?.path != null) {
          await state.sendMedia(_chatId, f!.path!, 'file', f.name, 'application/octet-stream');
        }
      case _Attach.location:
        await _sendLocation();
      case _Attach.poll:
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PollComposer(chatId: _chatId)));
      case _Attach.games:
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GamesScreen()));
      case _Attach.ai:
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiListScreen()));
    }
  }

  Future<void> _sendPicked(ImageSource source) async {
    final state = context.sync;
    final x = await ImagePicker().pickImage(source: source, imageQuality: 85, maxWidth: 2560);
    if (x == null) return;
    final bytes = await File(x.path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    await state.sendMedia(_chatId, x.path, 'image', x.name, 'image/jpeg', w: frame.image.width, h: frame.image.height);
    frame.image.dispose();
    codec.dispose();
  }

  Future<void> _sendLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) throw 'Turn on location services first.';
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      throw 'Sync needs location access to share where you are.';
    }
    final pos = await Geolocator.getCurrentPosition();
    final lat = pos.latitude.toStringAsFixed(6), lng = pos.longitude.toStringAsFixed(6);
    await _send('📍 https://www.openstreetmap.org/?mlat=$lat&mlon=$lng#map=16/$lat/$lng');
  }

  void _pickEmoji() {
    showGlassSheet<void>(
      context,
      (ctx) => SizedBox(
        height: 280,
        child: GridView.count(
          crossAxisCount: 8,
          padding: const EdgeInsets.all(12),
          children: [
            for (final e in kEmoji)
              GestureDetector(
                onTap: () {
                  _input.text += e;
                  _input.selection = TextSelection.collapsed(offset: _input.text.length);
                  setState(() {});
                },
                child: Center(child: Text(e, style: const TextStyle(fontSize: 24))),
              ),
          ],
        ),
      ),
    );
  }

  void _openInfo() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatInfoScreen(chatId: _chatId)));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final chat = state.chat(_chatId);
            if (chat == null) {
              return const SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(padding: EdgeInsets.all(16), child: GlassBackButton()),
                ),
              );
            }
            final messages = state.thread(_chatId);
            final top = MediaQuery.of(context).padding.top;
            return Stack(
              children: [
                Positioned.fill(
                  child: Column(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: _focus.unfocus,
                          child: _Thread(
                            chat: chat,
                            messages: messages,
                            controller: _scroll,
                            typing: state.typingIn(_chatId),
                            topPadding: top + 62,
                            onReply: _startReply,
                            onEdit: _startEdit,
                            showHero: state.threadComplete(_chatId) || messages.isEmpty,
                            onOpenInfo: _openInfo,
                          ),
                        ),
                      ),
                      if (chat.readOnly)
                        SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(tr('service_read_only'), style: SyncText.secondary,
                                textAlign: TextAlign.center),
                          ),
                        )
                      else if (chat.isRequest)
                        _RequestBar(chat: chat)
                      else if (chat.hasLeft)
                        const SafeArea(
                          top: false,
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text("You're no longer in this group.", style: SyncText.secondary),
                          ),
                        )
                      else
                        _Composer(
                          attachKey: _attachKey,
                          controller: _input,
                          focus: _focus,
                          onChanged: _onChanged,
                          onSend: () => _send(),
                          onLike: () => _send('👍'),
                          onMenu: _openMenu,
                          onEmoji: _pickEmoji,
                          replyTo: _replyTo,
                          editing: _editing,
                          onCancelContext: () => setState(() {
                            if (_editing != null) _input.clear();
                            _replyTo = null;
                            _editing = null;
                          }),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  top: top + 8,
                  left: 16,
                  right: 16,
                  child: _Header(chat: chat, onInfo: _openInfo, subtitle: _subtitle(chat)),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String? _subtitle(Chat chat) {
    final state = context.sync;
    if (state.typingIn(_chatId) != null) return 'typing…';
    if (chat.isGroup || chat.peer == null) return null;
    final p = state.presence[chat.peer!.id];
    if (p == null) return null;
    return p.online ? 'Active now' : lastSeenText(p.lastSeen);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.chat, required this.onInfo, this.subtitle});
  final Chat chat;
  final VoidCallback onInfo;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    void noCalls() => showToast(context, "Voice and video calls aren't available yet.");
    return Row(
      children: [
        const GlassBackButton(),
        const SizedBox(width: 8),
        Expanded(
          child: PressScale(
            scale: 0.97,
            onTap: onInfo,
            child: SizedBox(
              height: 40,
              child: Glass(
                radius: 20,
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    Avatar(id: chat.avatarId, name: chat.title, size: 32, group: chat.isGroup, icon: chat.icon),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  chat.title,
                                  style: SyncText.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (chat.isVerified) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.verified_rounded, size: 13, color: SyncColors.accent),
                              ],
                            ],
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              style: SyncText.caption.copyWith(fontSize: 10.5),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GlassIconButton(icon: Icons.call_outlined, tooltip: tr('voice_call'), onTap: noCalls),
        const SizedBox(width: 8),
        GlassIconButton(icon: Icons.videocam_outlined, tooltip: tr('video_call'), onTap: noCalls),
      ],
    );
  }
}

class _Thread extends StatelessWidget {
  const _Thread({
    required this.chat,
    required this.messages,
    required this.controller,
    required this.typing,
    required this.topPadding,
    required this.onReply,
    required this.onEdit,
    required this.showHero,
    required this.onOpenInfo,
  });

  final Chat chat;
  final List<Message> messages; // newest first
  final ScrollController controller;
  final String? typing;
  final double topPadding;
  final ValueChanged<Message> onReply;
  final ValueChanged<Message> onEdit;
  final bool showHero;
  final VoidCallback onOpenInfo;

  @override
  Widget build(BuildContext context) {
    final extra = typing != null ? 1 : 0;
    // Align + shrinkWrap: a short thread sits under the header, as in the design,
    // while a long one still scrolls from the newest message.
    return Align(
      alignment: Alignment.topCenter,
      child: ListView.builder(
        shrinkWrap: true,
        controller: controller,
        reverse: true,
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: EdgeInsets.fromLTRB(14, topPadding, 14, 12),
        itemCount: messages.length + extra + (showHero ? 1 : 0),
        itemBuilder: (context, raw) {
          if (extra == 1 && raw == 0) return const _TypingBubble();
          final i = raw - extra;
          if (i == messages.length) return _Hero(chat: chat, onTap: onOpenInfo);
          final m = messages[i];
          final older = i + 1 < messages.length ? messages[i + 1] : null;
          final newer = i > 0 ? messages[i - 1] : null;
          final newGap = older == null || m.time.difference(older.time).inMinutes >= 15;
          final firstInRun = newGap || older.sender != m.sender;
          final lastInRun = newer == null || newer.sender != m.sender || newer.time.difference(m.time).inMinutes >= 15;
          final sender = chat.members.where((u) => u.id == m.sender).firstOrNull;
          return Column(
            key: ValueKey(m.id),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (newGap)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Center(child: Text(separatorTime(m.time), style: SyncText.caption.copyWith(fontSize: 13))),
                ),
              MessageBubble(
                message: m,
                sender: sender,
                isGroup: chat.isGroup,
                showAvatar: !m.outgoing && firstInRun,
                showName: chat.isGroup && !m.outgoing && firstInRun,
                // Status under the newest outgoing message only, to keep the thread quiet.
                showStatus: m.outgoing && i == messages.indexWhere((x) => x.outgoing),
                topGap: firstInRun ? 6 : 3,
                bottomGap: lastInRun ? 3 : 0,
                onReply: onReply,
                onEdit: onEdit,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.chat, required this.onTap});
  final Chat chat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final others = chat.members.where((u) => u.id != context.sync.me?.id).toList();
    // Sync's own two chats have nobody on the other side, so there is no peer to
    // read a username from.
    final peer = chat.peer;
    final subtitle = chat.isSaved
        ? tr('saved_subtitle')
        : chat.isService
        ? tr('service_subtitle')
        : chat.isGroup
        ? '${chat.members.length} friends in Sync'
        : (peer == null || peer.username.isEmpty ? 'On Sync' : '@${peer.username}');
    final intro = chat.isSaved
        ? tr('saved_intro')
        : chat.isService
        // Said once, at the foot of the chat, where the composer would be.
        ? ''
        : chat.isGroup
        ? 'Say hi to your new group, ${chat.title}.'
        : 'Messages with ${chat.title} are end-to-end encrypted.';
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Column(
          children: [
            Avatar(id: chat.avatarId, name: chat.title, size: 88, group: chat.isGroup, icon: chat.icon),
            const SizedBox(height: 10),
            Text(chat.title, style: SyncText.title, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(subtitle, style: SyncText.secondary),
            if (chat.isGroup && others.isNotEmpty) ...[const SizedBox(height: 10), _AvatarStack(users: others)],
            if (intro.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(intro, style: SyncText.secondary.copyWith(fontSize: 13), textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}

class _AvatarStack extends StatelessWidget {
  const _AvatarStack({required this.users});
  final List<SyncUser> users;

  @override
  Widget build(BuildContext context) {
    final shown = users.take(5).toList();
    const size = 38.0, step = 28.0;
    return SizedBox(
      width: size + step * (shown.length - 1),
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: SyncColors.bgMid, width: 1.5),
                ),
                child: Avatar(id: shown[i].id, name: shown[i].displayName, size: size - 3),
              ),
            ),
        ],
      ),
    );
  }
}

class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(left: 34, top: 6, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: SyncColors.bubbleIn, borderRadius: BorderRadius.circular(16)),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.35 + 0.6 * _pulse(_c.value, i)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  double _pulse(double t, int i) {
    final x = (t - i * 0.18) % 1.0;
    return x < 0.5 ? x * 2 : 2 - x * 2;
  }
}

class _RequestBar extends StatelessWidget {
  const _RequestBar({required this.chat});
  final Chat chat;

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 24,
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                chat.isGroup
                    ? 'You were invited to ${chat.title}. They won\'t know you\'ve seen messages until you accept.'
                    : '${chat.title} wants to message you. They won\'t know you\'ve seen this until you accept.',
                style: SyncText.secondary.copyWith(fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: chat.isGroup ? 'Delete' : 'Block',
                      onTap: () async {
                        final nav = Navigator.of(context);
                        await guarded(context, () async {
                          if (chat.peer != null) await state.setBlocked(chat.peer!.id, true);
                          await state.deleteChat(chat.id);
                        });
                        nav.maybePop();
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GlassButton(
                      label: tr('accept'),
                      primary: true,
                      onTap: () => guarded(context, () async {
                        await state.acceptRequest(chat.id);
                        await state.markRead(chat.id);
                      }),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.attachKey,
    required this.controller,
    required this.focus,
    required this.onChanged,
    required this.onSend,
    required this.onLike,
    required this.onMenu,
    required this.onEmoji,
    required this.replyTo,
    required this.editing,
    required this.onCancelContext,
  });

  final GlobalKey attachKey;
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onLike;
  final VoidCallback onMenu;
  final VoidCallback onEmoji;
  final Message? replyTo;
  final Message? editing;
  final VoidCallback onCancelContext;

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.trim().isNotEmpty;
    final ctxMessage = editing ?? replyTo;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ctxMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Glass(
                  radius: 14,
                  padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                  child: Row(
                    children: [
                      Icon(
                        editing != null ? Icons.edit_outlined : Icons.reply_rounded,
                        size: 18,
                        color: SyncColors.activeTab,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${editing != null ? 'Editing' : 'Replying to'}: ${ctxMessage.preview}',
                          style: SyncText.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      GestureDetector(
                        onTap: onCancelContext,
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded, size: 18, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                KeyedSubtree(
                  key: attachKey,
                  child: GlassIconButton(
                    icon: Icons.apps_rounded,
                    size: 44,
                    iconSize: 24,
                    tooltip: tr('more_options'),
                    onTap: onMenu,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Glass(
                    radius: 22,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const SizedBox(width: 14),
                          Expanded(
                            child: TextField(
                              controller: controller,
                              focusNode: focus,
                              onChanged: onChanged,
                              minLines: 1,
                              maxLines: 5,
                              textCapitalization: TextCapitalization.sentences,
                              style: SyncText.body,
                              decoration: InputDecoration(
                                hintText: 'Aa',
                                hintStyle: SyncText.body.copyWith(color: SyncColors.textSecondary),
                                border: InputBorder.none,
                                isCollapsed: true,
                                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: onEmoji,
                            child: const Padding(
                              padding: EdgeInsets.all(10),
                              child: Icon(Icons.sentiment_satisfied_alt_outlined, color: Colors.white, size: 24),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: hasText || editing != null
                      ? GlassIconButton(
                          key: const ValueKey('send'),
                          icon: editing != null ? Icons.check_rounded : Icons.send_rounded,
                          size: 44,
                          iconSize: 22,
                          tooltip: tr('send'),
                          onTap: onSend,
                        )
                      : GlassIconButton(
                          key: const ValueKey('like'),
                          icon: Icons.thumb_up_outlined,
                          size: 44,
                          iconSize: 22,
                          tooltip: tr('send_like'),
                          onTap: onLike,
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _Attach { camera, gallery, record, file, location, poll, games, ai }

class _AttachRoute extends PopupRoute<_Attach> {
  _AttachRoute({required this.anchor});
  final Offset anchor;

  @override
  Color? get barrierColor => Colors.transparent;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Close menu';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final media = MediaQuery.of(context);
    return Stack(
      children: [
        Positioned(
          left: 14,
          bottom: media.size.height - anchor.dy + 2,
          child: _AttachPanel(animation: animation),
        ),
      ],
    );
  }
}

class _AttachPanel extends StatelessWidget {
  const _AttachPanel({required this.animation});
  final Animation<double> animation;

  static const _items = [
    (_Attach.camera, Icons.camera_alt_outlined, 'Camera'),
    (_Attach.gallery, Icons.image_outlined, 'Gallery'),
    (_Attach.record, Icons.mic_none_rounded, 'Record'),
    (_Attach.file, Icons.description_outlined, 'Share a file'),
    (_Attach.location, Icons.near_me_outlined, 'Location'),
    (_Attach.poll, Icons.bar_chart_rounded, 'Poll'),
    (_Attach.games, Icons.sports_esports_outlined, 'Play games'),
  ];

  @override
  Widget build(BuildContext context) {
    // A real spring curve rather than an easing preset: it overshoots, then settles.
    final spring = _SpringCurve(SyncSprings.bouncy);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final closing = animation.status == AnimationStatus.reverse;
        final t = closing ? animation.value : spring.transform(animation.value);
        return Transform.scale(
          scale: 0.4 + 0.6 * t,
          alignment: Alignment.bottomLeft,
          child: Opacity(opacity: animation.value.clamp(0.0, 1.0), child: child),
        );
      },
      child: SizedBox(
        width: 216,
        child: Glass(
          radius: 26,
          blur: 30,
          tint: 0.2,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (action, icon, label) in _items)
                  _row(context, action, Icon(icon, color: Colors.white, size: 24), label),
                _row(context, _Attach.ai, const SyncOrb(size: 24, animate: false), 'Sync AI'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _Attach action, Widget icon, String label) {
    return PressScale(
      scale: 0.96,
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.pop(context, action);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9.5),
        child: Row(
          children: [
            SizedBox.square(dimension: 26, child: Center(child: icon)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label, style: SyncText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpringCurve extends Curve {
  _SpringCurve(SpringDescription spring) : _sim = SpringSimulation(spring, 0, 1, 0);
  final SpringSimulation _sim;

  @override
  double transformInternal(double t) => _sim.x(t * 0.9);
}

const kEmoji = [
  '😀',
  '😂',
  '🥹',
  '😍',
  '😘',
  '😎',
  '🤔',
  '😴',
  '😭',
  '😡',
  '🥳',
  '🤯',
  '😱',
  '🤗',
  '🙃',
  '😅',
  '👍',
  '👎',
  '👏',
  '🙏',
  '💪',
  '👋',
  '🤝',
  '✌️',
  '❤️',
  '🧡',
  '💛',
  '💚',
  '💙',
  '💜',
  '🔥',
  '✨',
  '🎉',
  '🎂',
  '🍕',
  '☕',
  '⚽',
  '🚗',
  '✈️',
  '🏠',
  '📷',
  '💡',
  '📌',
  '✅',
  '❌',
  '⭐',
  '🌙',
  '☀️',
];
