import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/localization.dart';
import '../core/models.dart';
import '../ui/avatar.dart';
import '../ui/format.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';

const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.sender,
    required this.isGroup,
    required this.showAvatar,
    required this.showName,
    required this.showStatus,
    required this.topGap,
    required this.bottomGap,
    required this.onReply,
    required this.onEdit,
  });

  final Message message;
  final SyncUser? sender;
  final bool isGroup;
  final bool showAvatar;
  final bool showName;
  final bool showStatus;
  final double topGap;
  final double bottomGap;
  final ValueChanged<Message> onReply;
  final ValueChanged<Message> onEdit;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> with SingleTickerProviderStateMixin {
  // Swipe right to reply: the bubble follows the finger, then springs home.
  late final AnimationController _drag = AnimationController.unbounded(vsync: this, value: 0);
  bool _armed = false;

  Message get m => widget.message;

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final next = (_drag.value + d.delta.dx * 0.6).clamp(0.0, 80.0);
    _drag.value = next;
    if (next > 50 && !_armed) {
      _armed = true;
      HapticFeedback.lightImpact();
    } else if (next <= 50) {
      _armed = false;
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (_armed && !m.deleted) widget.onReply(m);
    _armed = false;
    _drag.animateWith(SpringSimulation(SyncSprings.snappy, _drag.value, 0, d.velocity.pixelsPerSecond.dx));
  }

  void _openActions() {
    if (m.deleted) return;
    HapticFeedback.mediumImpact();
    final state = context.sync;
    final parent = context;
    showGlassSheet<void>(
      context,
      (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final e in _quickReactions)
                  PressScale(
                    scale: 0.8,
                    onTap: () {
                      Navigator.pop(ctx);
                      final mine = m.reactions.where((r) => r['user'] == state.me?.id).firstOrNull;
                      guarded(parent, () => state.react(m.id, mine?['emoji'] == e ? '' : e));
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(e, style: const TextStyle(fontSize: 30)),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: SyncColors.divider),
          GlassRow(
            icon: Icons.reply_rounded,
            title: tr('reply'),
            chevron: false,
            onTap: () {
              Navigator.pop(ctx);
              widget.onReply(m);
            },
          ),
          if (m.kind == 'text')
            GlassRow(
              icon: Icons.copy_rounded,
              title: tr('copy'),
              chevron: false,
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: m.text));
              },
            ),
          if (m.outgoing && m.kind == 'text')
            GlassRow(
              icon: Icons.edit_outlined,
              title: tr('edit'),
              chevron: false,
              onTap: () {
                Navigator.pop(ctx);
                widget.onEdit(m);
              },
            ),
          if (m.outgoing)
            GlassRow(
              icon: Icons.delete_outline_rounded,
              title: tr('delete_for_everyone'),
              chevron: false,
              destructive: true,
              onTap: () {
                Navigator.pop(ctx);
                guarded(parent, () => state.deleteMessage(m.id));
              },
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final out = m.outgoing;
    final body = Column(
      crossAxisAlignment: out ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showName)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 3),
            child: Text(widget.sender?.displayName ?? 'Member', style: SyncText.caption),
          ),
        if (m.replyPreview != null) _ReplyQuote(preview: m.replyPreview!),
        GestureDetector(onLongPress: _openActions, child: _content(context)),
        if (m.reactions.isNotEmpty) _Reactions(reactions: m.reactions, out: out),
        if (widget.showStatus)
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 4),
            child: _Status(status: m.status),
          ),
      ],
    );

    return Padding(
      padding: EdgeInsets.only(top: widget.topGap, bottom: widget.bottomGap),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: AnimatedBuilder(
          animation: _drag,
          builder: (context, child) => Transform.translate(offset: Offset(_drag.value, 0), child: child),
          child: Row(
            mainAxisAlignment: out ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!out) ...[
                SizedBox(
                  width: 26,
                  child: widget.showAvatar
                      ? Padding(
                          padding: EdgeInsets.only(top: widget.showName ? 18 : 2),
                          child: Avatar(id: m.sender, name: widget.sender?.displayName ?? '?', size: 26),
                        )
                      : null,
                ),
                const SizedBox(width: 6),
              ],
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                child: body,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (m.deleted) {
      return _Bubble(
        out: m.outgoing,
        muted: true,
        child: Text(tr('message_deleted'), style: SyncText.secondary.copyWith(fontStyle: FontStyle.italic)),
      );
    }
    switch (m.kind) {
      case 'service':
        // Centred and plain, so a notice from Sync never resembles a message
        // somebody sent. The words come from the app, not from the wire.
        return Align(
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
            child: Glass(
              radius: 14,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text(
                  m.serviceText,
                  style: SyncText.secondary.copyWith(height: 1.35),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        );
      case 'image':
        return _ImageBubble(message: m);
      case 'poll':
        return _PollBubble(message: m);
      case 'file':
        final mime = m.content['mime'] as String? ?? '';
        return mime.startsWith('audio/') ? _VoiceBubble(message: m) : _FileBubble(message: m);
      default:
        if (isEmojiOnly(m.text)) return _BigEmoji(text: m.text.trim());
        return _Bubble(
          out: m.outgoing,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Linkified(text: m.text),
              if (m.edited) Text('edited', style: SyncText.caption.copyWith(fontSize: 10.5)),
            ],
          ),
        );
    }
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.child, required this.out, this.muted = false});
  final Widget child;
  final bool out;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: out && !muted ? null : SyncColors.bubbleIn,
        gradient: out && !muted ? const LinearGradient(colors: [Color(0xFF3C7BFF), SyncColors.accent]) : null,
      ),
      child: child,
    );
  }
}

/// Links open only in the system browser, and only for http(s).
class _Linkified extends StatefulWidget {
  const _Linkified({required this.text});
  final String text;

  @override
  State<_Linkified> createState() => _LinkifiedState();
}

class _LinkifiedState extends State<_Linkified> {
  static final _url = RegExp(r'https?://[^\s]+');
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = SyncText.body.copyWith(fontWeight: FontWeight.w400);
    if (!_url.hasMatch(widget.text)) return Text(widget.text, style: style);
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final spans = <InlineSpan>[];
    var pos = 0;
    for (final match in _url.allMatches(widget.text)) {
      if (match.start > pos) spans.add(TextSpan(text: widget.text.substring(pos, match.start)));
      final link = match.group(0)!;
      final r = TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
      _recognizers.add(r);
      spans.add(
        TextSpan(
          text: link,
          recognizer: r,
          style: const TextStyle(decoration: TextDecoration.underline),
        ),
      );
      pos = match.end;
    }
    if (pos < widget.text.length) spans.add(TextSpan(text: widget.text.substring(pos)));
    return Text.rich(TextSpan(children: spans), style: style);
  }
}

/// Oversized emoji with the little wave the design shows on its hand.
class _BigEmoji extends StatefulWidget {
  const _BigEmoji({required this.text});
  final String text;

  @override
  State<_BigEmoji> createState() => _BigEmojiState();
}

class _BigEmojiState extends State<_BigEmoji> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final decay = 1 - _c.value;
        return Transform.rotate(
          angle: math.sin(_c.value * math.pi * 5) * 0.28 * decay,
          alignment: Alignment.bottomCenter,
          child: child,
        );
      },
      child: Text(widget.text, style: const TextStyle(fontSize: 52, height: 1.15)),
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.preview});
  final Json preview;

  @override
  Widget build(BuildContext context) {
    final kind = preview['kind'] as String? ?? 'text';
    final text = kind == 'text' ? (preview['text'] as String? ?? '') : 'Attachment';
    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            preview['sender'] as String? ?? '',
            style: SyncText.caption.copyWith(fontWeight: FontWeight.w600, fontSize: 11),
          ),
          Text(text, style: SyncText.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _Reactions extends StatelessWidget {
  const _Reactions({required this.reactions, required this.out});
  final List<Json> reactions;
  final bool out;

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final r in reactions) {
      final e = r['emoji'] as String;
      counts[e] = (counts[e] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xCC24355F),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          counts.entries.map((e) => e.value > 1 ? '${e.key} ${e.value}' : e.key).join(' '),
          style: const TextStyle(fontSize: 13, color: Colors.white),
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (status) {
      'sending' => ('Sending', Icons.schedule_rounded),
      'sent' => ('Sent', Icons.check_rounded),
      'delivered' => ('Delivered', Icons.done_all_rounded),
      'read' => ('Seen', Icons.done_all_rounded),
      _ => ('', null),
    };
    if (icon == null) return const SizedBox.shrink();
    final color = status == 'read' ? SyncColors.activeTab : SyncColors.textTertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(label, style: SyncText.caption.copyWith(fontSize: 11, color: color)),
      ],
    );
  }
}

class _ImageBubble extends StatefulWidget {
  const _ImageBubble({required this.message});
  final Message message;

  @override
  State<_ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<_ImageBubble> {
  bool _loading = false;
  bool _failed = false;

  Future<void> _download() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await context.sync.downloadMedia(widget.message.id);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void initState() {
    super.initState();
    if (!_hasFile) WidgetsBinding.instance.addPostFrameCallback((_) => _download());
  }

  bool get _hasFile {
    final p = widget.message.localPath;
    return p != null && File(p).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.message.content;
    final w = (c['w'] as int? ?? 0), h = (c['h'] as int? ?? 0);
    final ratio = w > 0 && h > 0 ? (w / h).clamp(0.6, 1.8) : 1.0;
    final path = widget.message.localPath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: 240,
        child: AspectRatio(
          aspectRatio: ratio,
          child: _hasFile
              ? GestureDetector(
                  onTap: () => Navigator.of(
                    context,
                    rootNavigator: true,
                  ).push(MaterialPageRoute(builder: (_) => _PhotoViewer(path: path))),
                  child: Image.file(File(path!), fit: BoxFit.cover, cacheWidth: 720),
                )
              : ColoredBox(
                  color: SyncColors.bubbleIn,
                  child: Center(
                    child: _loading
                        ? const CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
                        : IconButton(
                            tooltip: tr('download_photo'),
                            onPressed: _download,
                            icon: Icon(_failed ? Icons.refresh_rounded : Icons.download_rounded, color: Colors.white),
                          ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(maxScale: 5, child: Image.file(File(path), fit: BoxFit.contain)),
          ),
          const SafeArea(
            child: Padding(padding: EdgeInsets.all(16), child: GlassBackButton()),
          ),
        ],
      ),
    );
  }
}

class _FileBubble extends StatefulWidget {
  const _FileBubble({required this.message});
  final Message message;

  @override
  State<_FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends State<_FileBubble> {
  bool _busy = false;

  Future<void> _open() async {
    final state = context.sync;
    setState(() => _busy = true);
    await guarded(context, () async {
      var path = widget.message.localPath;
      if (path == null || !File(path).existsSync()) {
        final r = await state.backend('downloadMedia', {'message_id': widget.message.id});
        path = r['path'] as String;
      }
      await OpenFilex.open(path);
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.message.content;
    return GestureDetector(
      onTap: _busy ? null : _open,
      child: _Bubble(
        out: widget.message.outgoing,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 36,
              child: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.description_outlined, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    c['name'] as String? ?? 'File',
                    style: SyncText.body.copyWith(fontSize: 14),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(fileSize(c['size'] as int? ?? 0), style: SyncText.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceBubble extends StatefulWidget {
  const _VoiceBubble({required this.message});
  final Message message;

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  AudioPlayer? _player;
  bool _playing = false;
  bool _busy = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player?.pause();
      setState(() => _playing = false);
      return;
    }
    final state = context.sync;
    setState(() => _busy = true);
    await guarded(context, () async {
      var path = widget.message.localPath;
      if (path == null || !File(path).existsSync()) {
        final r = await state.backend('downloadMedia', {'message_id': widget.message.id});
        path = r['path'] as String;
      }
      final p = _player ??= AudioPlayer()
        ..onPlayerComplete.listen((_) {
          if (mounted) setState(() => _playing = false);
        });
      await p.play(DeviceFileSource(path));
      if (mounted) setState(() => _playing = true);
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return _Bubble(
      out: widget.message.outgoing,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _busy ? null : _toggle,
            child: Semantics(
              button: true,
              label: _playing ? 'Pause voice message' : 'Play voice message',
              child: SizedBox.square(
                dimension: 32,
                child: _busy
                    ? const Padding(
                        padding: EdgeInsets.all(7),
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28),
              ),
            ),
          ),
          const SizedBox(width: 6),
          for (var i = 0; i < 18; i++)
            Container(
              width: 2.5,
              height: 5 + 15 * (0.5 + 0.5 * math.sin(i * 1.7)).abs(),
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(color: Colors.white70, borderRadius: BorderRadius.circular(2)),
            ),
        ],
      ),
    );
  }
}

class _PollBubble extends StatelessWidget {
  const _PollBubble({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final state = context.sync;
    final options = (message.content['options'] as List? ?? const []).cast<String>();
    final votes = message.votes;
    final mine = votes.where((v) => v['user'] == state.me?.id).firstOrNull?['option'] as int?;
    return SizedBox(
      width: 260,
      child: Glass(
        radius: 18,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.content['question'] as String? ?? '',
              style: SyncText.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < options.length; i++)
              _PollOption(
                label: options[i],
                count: votes.where((v) => v['option'] == i).length,
                total: votes.length,
                selected: mine == i,
                onTap: () => guarded(context, () => state.vote(message.id, i)),
              ),
            const SizedBox(height: 2),
            Text('${votes.length} ${votes.length == 1 ? 'vote' : 'votes'}', style: SyncText.caption),
          ],
        ),
      ),
    );
  }
}

class _PollOption extends StatelessWidget {
  const _PollOption({
    required this.label,
    required this.count,
    required this.total,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final int count;
  final int total;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fraction = total == 0 ? 0.0 : count / total;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PressScale(
        scale: 0.98,
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: Colors.white.withValues(alpha: 0.08))),
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: fraction),
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    builder: (context, v, _) => FractionallySizedBox(
                      widthFactor: v,
                      heightFactor: 1,
                      child: ColoredBox(color: SyncColors.accent.withValues(alpha: selected ? 0.8 : 0.4)),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    if (selected) ...[
                      const Icon(Icons.check_circle_rounded, size: 16, color: Colors.white),
                      const SizedBox(width: 6),
                    ],
                    Expanded(child: Text(label, style: SyncText.body.copyWith(fontSize: 14))),
                    if (total > 0) Text('$count', style: SyncText.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
