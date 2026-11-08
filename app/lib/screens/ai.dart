import 'dart:math';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../ui/avatar.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';

const _maxChars = 18000;
const _maxTurns = 40;

class AiPersona {
  const AiPersona({required this.id, required this.name, required this.prompt, this.builtIn = false});
  final String id;
  final String name;
  final String prompt;
  final bool builtIn;

  Json toJson() => {'id': id, 'name': name, 'prompt': prompt};
  factory AiPersona.fromJson(Json j) =>
      AiPersona(id: j['id'] as String, name: j['name'] as String, prompt: j['prompt'] as String? ?? '');
}

const _defaultPersona = AiPersona(id: 'sync', name: 'Sync AI', prompt: '', builtIn: true);

/// Picks the newest turns that fit the gateway's limits and form a valid conversation:
/// alternating roles, starting and ending with the person.
List<Json> trimTurns(List<Json> history) {
  final picked = <Json>[];
  var total = 0;
  for (final t in history.reversed) {
    final n = (t['text'] as String).length;
    if (picked.length >= _maxTurns || total + n > _maxChars) break;
    picked.insert(0, t);
    total += n;
  }
  while (picked.isNotEmpty && picked.first['role'] != 'user') {
    picked.removeAt(0);
  }
  return picked;
}

class AiListScreen extends StatefulWidget {
  const AiListScreen({super.key});

  @override
  State<AiListScreen> createState() => _AiListScreenState();
}

class _AiListScreenState extends State<AiListScreen> {
  List<AiPersona> _custom = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final v = await context.sync.getKv('ai_personas');
    if (!mounted) return;
    setState(() {
      _custom = (v as List? ?? const []).cast<Map>().map((e) => AiPersona.fromJson(e.cast<String, dynamic>())).toList();
    });
  }

  Future<void> _create() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreateAiScreen()));
    await _load();
  }

  void _open(AiPersona p) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AiChatScreen(persona: p)));

  Future<void> _delete(AiPersona p) async {
    final state = context.sync;
    final yes = await confirmSheet(
      context,
      title: 'Delete ${p.name}?',
      body: 'Its chat history on this device goes with it.',
      action: 'Delete',
    );
    if (!yes || !mounted) return;
    await guarded(context, () async {
      final rest = _custom.where((x) => x.id != p.id).map((x) => x.toJson()).toList();
      await state.setKv('ai_personas', rest);
      await state.setKv('ai_chat_${p.id}', <Object>[]);
      await _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: 'Chat with AIs',
      actions: [GlassIconButton(icon: Icons.add_rounded, iconSize: 24, tooltip: 'Create an AI', onTap: _create)],
      child: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.all(16),
        children: [
          GlassGroup(
            children: [
              GlassRow(
                leading: const SizedBox.square(dimension: 36, child: Center(child: SyncOrb(size: 30, animate: false))),
                title: _defaultPersona.name,
                subtitle: 'General assistant',
                onTap: () => _open(_defaultPersona),
              ),
              for (final p in _custom)
                GestureDetector(
                  onLongPress: () => _delete(p),
                  child: GlassRow(
                    leading: Avatar(id: p.id, name: p.name, size: 36),
                    title: p.name,
                    subtitle: p.prompt,
                    onTap: () => _open(p),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            "AI chats aren't end-to-end encrypted: this server and the AI provider process what you send. Your other chats are never shared with the AI.",
            style: SyncText.caption,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class CreateAiScreen extends StatefulWidget {
  const CreateAiScreen({super.key});

  @override
  State<CreateAiScreen> createState() => _CreateAiScreenState();
}

class _CreateAiScreenState extends State<CreateAiScreen> {
  final _name = TextEditingController();
  final _prompt = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.sync;
    final nav = Navigator.of(context);
    await guarded(context, () async {
      final existing = (await state.getKv('ai_personas') as List? ?? const []).cast<Object>();
      final rng = Random.secure();
      final id = List.generate(8, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await state.setKv('ai_personas', [
        ...existing,
        AiPersona(id: id, name: _name.text.trim(), prompt: _prompt.text.trim()).toJson(),
      ]);
      nav.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ready = _name.text.trim().isNotEmpty && _prompt.text.trim().isNotEmpty;
    return GlassPage(
      title: 'Create an AI',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Avatar(id: _name.text, name: _name.text.isEmpty ? 'AI' : _name.text, size: 84),
          ),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 6),
            child: Text('Name', style: SyncText.section),
          ),
          GlassField(controller: _name, hint: 'Travel Buddy', onChanged: (_) => setState(() {})),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 6),
            child: Text('Personality', style: SyncText.section),
          ),
          GlassField(
            controller: _prompt,
            hint: 'A cheerful guide who suggests cheap trips and asks where I want to go.',
            maxLines: 7,
            minLines: 4,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 22),
          GlassButton(label: 'Create', primary: true, onTap: ready ? _save : null),
        ],
      ),
    );
  }
}

class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key, required this.persona});
  final AiPersona persona;

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _input = TextEditingController();
  List<Json> _history = [];
  bool _thinking = false;

  String get _key => 'ai_chat_${widget.persona.id}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final v = await context.sync.getKv(_key);
      if (mounted) {
        setState(() => _history = (v as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList());
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _thinking) return;
    final state = context.sync;
    _input.clear();
    setState(() {
      _history = [
        ..._history,
        {'role': 'user', 'text': text},
      ];
      _thinking = true;
    });
    try {
      final reply = await state.askAi(trimTurns(_history), widget.persona.prompt);
      if (!mounted) return;
      setState(
        () => _history = [
          ..._history,
          {'role': 'assistant', 'text': reply},
        ],
      );
      await state.setKv(_key, _history);
    } catch (e) {
      if (!mounted) return;
      // Roles must alternate, so a failed turn comes off the history and back to the box.
      setState(() => _history = _history.sublist(0, _history.length - 1));
      _input.text = text;
      showToast(context, e);
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  Future<void> _clear() async {
    final state = context.sync;
    final yes = await confirmSheet(context, title: 'Clear this chat?', action: 'Clear');
    if (!yes || !mounted) return;
    await guarded(context, () async {
      await state.setKv(_key, <Object>[]);
      if (mounted) setState(() => _history = []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _history.reversed.toList();
    return GlassPage(
      title: widget.persona.name,
      actions: [
        if (_history.isNotEmpty)
          GlassIconButton(icon: Icons.delete_outline_rounded, tooltip: 'Clear chat', onTap: _clear),
      ],
      bottom: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: Row(
            children: [
              Expanded(
                child: GlassField(
                  controller: _input,
                  hint: 'Ask anything',
                  maxLines: 5,
                  minLines: 1,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              GlassIconButton(icon: Icons.send_rounded, size: 44, tooltip: 'Send', onTap: _thinking ? null : _send),
            ],
          ),
        ),
      ),
      child: _history.isEmpty && !_thinking
          ? EmptyState(
              icon: Icons.auto_awesome_outlined,
              title: 'Say hello to ${widget.persona.name}',
              body: widget.persona.builtIn
                  ? 'Ask a question, draft a message or talk an idea through.'
                  : widget.persona.prompt,
            )
          : ListView.builder(
              reverse: true,
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              padding: const EdgeInsets.all(14),
              itemCount: items.length + (_thinking ? 1 : 0),
              itemBuilder: (context, i) {
                if (_thinking && i == 0) {
                  return const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(padding: EdgeInsets.all(8), child: SyncOrb(size: 24)),
                  );
                }
                final t = items[i - (_thinking ? 1 : 0)];
                final mine = t['role'] == 'user';
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: mine ? null : SyncColors.bubbleIn,
                      gradient: mine ? const LinearGradient(colors: [Color(0xFF3C7BFF), SyncColors.accent]) : null,
                    ),
                    child: SelectableText(
                      t['text'] as String,
                      style: SyncText.body.copyWith(fontWeight: FontWeight.w400),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
