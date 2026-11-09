import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../core/localization.dart';
import '../ui/format.dart';
import '../ui/glass.dart';
import '../ui/scope.dart';
import '../ui/theme.dart';

/// Records a voice message. Returns the file path, or null if cancelled.
Future<String?> showVoiceRecorder(BuildContext context) {
  return showGlassSheet<String>(context, (_) => const _VoiceRecorder());
}

class _VoiceRecorder extends StatefulWidget {
  const _VoiceRecorder();

  @override
  State<_VoiceRecorder> createState() => _VoiceRecorderState();
}

class _VoiceRecorderState extends State<_VoiceRecorder> {
  final _recorder = AudioRecorder();
  Timer? _ticker;
  int _seconds = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _error = 'Sync needs microphone access to record.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(), path: path);
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't start recording: $e");
    }
  }

  Future<void> _finish(bool send) async {
    _ticker?.cancel();
    final nav = Navigator.of(context);
    final path = await _recorder.stop();
    if (!send && path != null) {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    }
    nav.pop(send ? path : null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _error == null ? Icons.mic_rounded : Icons.mic_off_rounded,
            color: _error == null ? SyncColors.danger : Colors.white,
            size: 40,
          ),
          const SizedBox(height: 10),
          Text(
            _error ?? '${_seconds ~/ 60}:${twoDigits(_seconds % 60)}',
            style: _error == null ? SyncText.title : SyncText.secondary,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: GlassButton(label: tr('cancel'), onTap: () => _finish(false)),
              ),
              if (_error == null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: GlassButton(label: tr('send'), primary: true, onTap: () => _finish(true)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class PollComposer extends StatefulWidget {
  const PollComposer({super.key, required this.chatId});
  final String chatId;

  @override
  State<PollComposer> createState() => _PollComposerState();
}

class _PollComposerState extends State<PollComposer> {
  final _question = TextEditingController();
  final _options = [TextEditingController(), TextEditingController()];

  @override
  void dispose() {
    _question.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  List<String> get _filled => _options.map((o) => o.text.trim()).where((t) => t.isNotEmpty).toList();

  Future<void> _send() async {
    final state = context.sync;
    final nav = Navigator.of(context);
    await guarded(context, () async {
      await state.sendPoll(widget.chatId, _question.text.trim(), _filled);
      nav.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: tr('poll'),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GlassField(controller: _question, hint: tr('ask_question'), autofocus: true, onChanged: (_) => setState(() {})),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(tr('options'), style: SyncText.section),
          ),
          for (var i = 0; i < _options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassField(controller: _options[i], hint: trp('option_n', ['${i + 1}']), onChanged: (_) => setState(() {})),
            ),
          if (_options.length < 10)
            TextButton.icon(
              onPressed: () => setState(() => _options.add(TextEditingController())),
              icon: const Icon(Icons.add_rounded, color: SyncColors.activeTab),
              label: Text(tr('add_option'), style: const TextStyle(color: SyncColors.activeTab)),
            ),
          const SizedBox(height: 14),
          GlassButton(
            label: tr('send_poll'),
            primary: true,
            onTap: _question.text.trim().isNotEmpty && _filled.length >= 2 ? _send : null,
          ),
        ],
      ),
    );
  }
}

class GamesScreen extends StatelessWidget {
  const GamesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: tr('play_games'),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GlassGroup(
            children: [
              GlassRow(
                icon: Icons.grid_3x3_rounded,
                title: tr('tictactoe'),
                subtitle: tr('play_phone'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TicTacToeScreen())),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Returns 'X', 'O', 'draw', or null while the game is still going.
String? ticTacToeResult(List<String?> b) {
  const lines = [
    [0, 1, 2],
    [3, 4, 5],
    [6, 7, 8],
    [0, 3, 6],
    [1, 4, 7],
    [2, 5, 8],
    [0, 4, 8],
    [2, 4, 6],
  ];
  for (final l in lines) {
    if (b[l[0]] != null && b[l[0]] == b[l[1]] && b[l[1]] == b[l[2]]) return b[l[0]];
  }
  return b.every((c) => c != null) ? 'draw' : null;
}

/// Wins if it can, blocks if it must, otherwise prefers centre, corners, then edges.
int ticTacToeMove(List<String?> b, Random rng) {
  int? finishing(String who) {
    for (var i = 0; i < 9; i++) {
      if (b[i] != null) continue;
      final next = [...b]..[i] = who;
      if (ticTacToeResult(next) == who) return i;
    }
    return null;
  }

  final decisive = finishing('O') ?? finishing('X');
  if (decisive != null) return decisive;
  if (b[4] == null) return 4;
  final free = [0, 2, 6, 8].where((i) => b[i] == null).toList();
  if (free.isNotEmpty) return free[rng.nextInt(free.length)];
  final edges = [1, 3, 5, 7].where((i) => b[i] == null).toList();
  return edges[rng.nextInt(edges.length)];
}

class TicTacToeScreen extends StatefulWidget {
  const TicTacToeScreen({super.key});

  @override
  State<TicTacToeScreen> createState() => _TicTacToeScreenState();
}

class _TicTacToeScreenState extends State<TicTacToeScreen> {
  final _rng = Random();
  List<String?> _board = List.filled(9, null);

  String? get _result => ticTacToeResult(_board);

  void _tap(int i) {
    if (_board[i] != null || _result != null) return;
    setState(() {
      _board[i] = 'X';
      if (_result == null) _board[ticTacToeMove(_board, _rng)] = 'O';
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final status = switch (result) {
      'X' => 'You won!',
      'O' => 'Your phone won.',
      'draw' => "It's a draw.",
      _ => 'Your turn',
    };
    return GlassPage(
      title: tr('tictactoe'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(status, style: SyncText.title),
            const SizedBox(height: 20),
            AspectRatio(
              aspectRatio: 1,
              child: GridView.count(
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                children: [
                  for (var i = 0; i < 9; i++)
                    PressScale(
                      onTap: () => _tap(i),
                      child: Glass(
                        radius: 18,
                        child: Center(
                          child: Text(
                            _board[i] ?? '',
                            style: SyncText.largeTitle.copyWith(
                              fontSize: 40,
                              color: _board[i] == 'X' ? Colors.white : SyncColors.activeTab,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (result != null)
              GlassButton(
                label: tr('play_again'),
                primary: true,
                onTap: () => setState(() => _board = List.filled(9, null)),
              ),
          ],
        ),
      ),
    );
  }
}
