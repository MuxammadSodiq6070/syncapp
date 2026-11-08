import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_app/core/app_state.dart';
import 'package:sync_app/core/localization.dart';
import 'package:sync_app/core/models.dart';
import 'package:sync_app/screens/ai.dart';
import 'package:sync_app/screens/chat_info.dart';
import 'package:sync_app/screens/chat_screen.dart';
import 'package:sync_app/screens/extras.dart';
import 'package:sync_app/screens/lists.dart';
import 'package:sync_app/screens/market.dart';
import 'package:sync_app/screens/onboarding.dart';
import 'package:sync_app/screens/people.dart';
import 'package:sync_app/screens/settings.dart';
import 'package:sync_app/screens/shell.dart';
import 'package:sync_app/screens/stories.dart';
import 'package:sync_app/ui/format.dart';
import 'package:sync_app/ui/glass.dart';
import 'package:sync_app/ui/scope.dart';
import 'package:sync_app/ui/theme.dart';

import 'support/fake_backend.dart';

const _phone = Size(390, 844);

Future<void> _loadFonts() async {
  final loader = FontLoader('Inter');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    loader.addFont(File('assets/fonts/Inter-$w.ttf').readAsBytes().then((b) => ByteData.sublistView(b)));
  }
  await loader.load();
  // Real icon glyphs instead of test boxes in the screenshots.
  final icons = FontLoader('MaterialIcons');
  final root = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/tools/flutter';
  final f = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (f.existsSync()) {
    icons.addFont(f.readAsBytes().then((b) => ByteData.sublistView(b)));
    await icons.load();
  }
}

Future<(AppState, FakeBackend)> _pump(WidgetTester tester, Widget screen, {FakeBackend? backend}) async {
  tester.view.physicalSize = _phone * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 47 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
  final fake = backend ?? FakeBackend();
  final state = AppState(fake);
  addTearDown(state.dispose);
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('shot'),
      child: SyncScope(
        state: state,
        gateway: 'ws://test:8787',
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(), home: screen),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump(const Duration(seconds: 2));
  return (state, fake);
}

/// Saves a screenshot for comparing against the Figma frames by eye.
Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['SYNC_SHOTS'];
  if (dir == null) return;
  await tester.pump(const Duration(seconds: 2));
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Widget _shotWrap(Widget child) => child;

void main() {
  setUpAll(_loadFonts);

  testWidgets('Home lists chats and stories like the design', (tester) async {
    await _pump(tester, _shotWrap(const ShellScreen()));
    // The header and the service chat are both called Sync, as in Telegram.
    expect(find.text('Sync'), findsNWidgets(2));
    expect(find.text('Yoshlar 2.0'), findsOneWidget);
    expect(find.text('Aziza Karimova'), findsOneWidget);
    expect(find.text('Create story'), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // unread badge
    expect(tester.takeException(), isNull);
    await _shot(tester, 'home');
  });

  testWidgets('Menu has every design row and all of them open', (tester) async {
    await _pump(tester, _shotWrap(const ShellScreen(initialTab: 2)));
    for (final t in [
      'Settings',
      'Marketplace',
      'Message requests',
      'Archive',
      'Friend requests',
      'Chat with AIs',
      'Create an AI',
      'Create community',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    await _shot(tester, 'menu');

    for (final (row, title) in const [
      ('Marketplace', 'Marketplace'),
      ('Message requests', 'Message requests'),
      ('Archive', 'Archive'),
      ('Friend requests', 'Friend requests'),
      ('Chat with AIs', 'Chat with AIs'),
      ('Create an AI', 'Create an AI'),
      ('Settings', 'Settings'),
    ]) {
      await tester.tap(find.text(row).first);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(title), findsWidgets, reason: row);
      expect(tester.takeException(), isNull, reason: row);
      await tester.tap(find.byIcon(Icons.chevron_left_rounded).hitTestable().first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
  });

  testWidgets('Group chat matches the design header, hero and composer', (tester) async {
    await _pump(tester, _shotWrap(const ChatScreen(chatId: FakeBackend.groupId)));
    expect(find.text('Yoshlar 2.0'), findsWidgets);
    expect(find.text('5 friends in Sync'), findsOneWidget);
    expect(find.text('Say hi to your new group, Yoshlar 2.0.'), findsOneWidget);
    expect(find.text("What's up guys?"), findsOneWidget);
    expect(find.text('Aa'), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, 'chat');
  });

  testWidgets('More options menu opens and lists its actions', (tester) async {
    await _pump(tester, _shotWrap(const ChatScreen(chatId: FakeBackend.groupId)));
    await tester.tap(find.byIcon(Icons.apps_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    for (final t in ['Camera', 'Gallery', 'Record', 'Share a file', 'Location', 'Poll', 'Play games', 'Sync AI']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(tester.takeException(), isNull);
    await _shot(tester, 'more_options');
  });

  testWidgets('Typing swaps like for send, and sending calls the core', (tester) async {
    final fake = FakeBackend();
    await _pump(tester, _shotWrap(const ChatScreen(chatId: FakeBackend.groupId)), backend: fake);
    await tester.enterText(find.byType(TextField), 'Hello Darkness');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);
    expect(fake.calls.where((c) => c['@type'] == 'setTyping'), hasLength(1));
    await _shot(tester, 'typing');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    final sent = fake.calls.where((c) => c['@type'] == 'sendMessage');
    expect(sent.single['text'], 'Hello Darkness');
    expect(sent.single['chat_id'], FakeBackend.groupId);
  });

  testWidgets('Like button sends a thumbs up', (tester) async {
    final fake = FakeBackend();
    await _pump(tester, _shotWrap(const ChatScreen(chatId: FakeBackend.groupId)), backend: fake);
    await tester.tap(find.byIcon(Icons.thumb_up_outlined));
    await tester.pump(const Duration(milliseconds: 300));
    expect(fake.calls.where((c) => c['@type'] == 'sendMessage').single['text'], '👍');
  });

  testWidgets('Nav bar switches tabs', (tester) async {
    await _pump(tester, _shotWrap(const ShellScreen()));
    await tester.tap(find.text('Stories').last);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Stories'), findsWidgets);
    await _shot(tester, 'stories');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Invented pages render without layout errors', (tester) async {
    for (final (name, page) in <(String, Widget)>[
      ('marketplace', const MarketplaceScreen()),
      ('post_listing', const PostListingScreen()),
      ('requests', const RequestsScreen()),
      ('archive', const ArchiveScreen()),
      ('friend_requests', const FriendRequestsScreen()),
      ('ai_list', const AiListScreen()),
      ('create_ai', const CreateAiScreen()),
      ('settings', const SettingsScreen()),
      ('profile', const EditProfileScreen()),
      ('recovery', const RecoveryKeyScreen()),
      ('blocked', const BlockedScreen()),
      ('new_chat', const NewChatScreen()),
      ('new_group', const NewGroupScreen()),
      ('community', const NewGroupScreen(community: true)),
      ('poll', const PollComposer(chatId: FakeBackend.groupId)),
      ('games', const GamesScreen()),
      ('tictactoe', const TicTacToeScreen()),
      ('story_composer', const StoryComposer()),
      ('onboarding', const OnboardingScreen()),
    ]) {
      await _pump(tester, _shotWrap(page));
      expect(tester.takeException(), isNull, reason: name);
      await _shot(tester, name);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('AI failure restores the message and keeps turns alternating', (tester) async {
    final fake = _FailingAi();
    await _pump(
      tester,
      _shotWrap(
        const AiChatScreen(
          persona: AiPersona(id: 'p', name: 'Test', prompt: ''),
        ),
      ),
      backend: fake,
    );
    await tester.enterText(find.byType(TextField), 'salom');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('salom'), findsOneWidget); // back in the box, not in the thread
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'salom');
    await tester.pump(const Duration(seconds: 5));
  });

  group('logic', () {
    test('trimTurns starts on a user turn and fits the limit', () {
      final turns = [
        {'role': 'assistant', 'text': 'x' * 10},
        {'role': 'user', 'text': 'a'},
        {'role': 'assistant', 'text': 'b'},
        {'role': 'user', 'text': 'c'},
      ];
      expect(trimTurns(turns).first['text'], 'a');
      final huge = [
        {'role': 'user', 'text': 'y' * 30000},
        {'role': 'assistant', 'text': 'b'},
        {'role': 'user', 'text': 'c'},
      ];
      expect(trimTurns(huge).map((t) => t['text']), ['c']);
    });

    test('isEmojiOnly', () {
      expect(isEmojiOnly('👋'), isTrue);
      expect(isEmojiOnly('👍🏽'), isTrue);
      expect(isEmojiOnly('hi 👋'), isFalse);
      expect(isEmojiOnly(''), isFalse);
      expect(isEmojiOnly('12'), isFalse);
    });

    test('shortTime', () {
      final now = DateTime(2026, 11, 6, 16);
      expect(shortTime(DateTime(2026, 11, 6, 9, 5), now: now), '9:05');
      expect(shortTime(DateTime(2026, 11, 4, 9), now: now), 'Wed');
      expect(shortTime(DateTime(2026, 1, 4), now: now), 'Jan 4');
    });

    test('tic-tac-toe plays sensibly', () {
      final rng = Random(1);
      // Takes a win.
      expect(ticTacToeMove(['O', 'O', null, 'X', 'X', null, null, null, null], rng), 2);
      // Blocks a loss.
      expect(ticTacToeMove(['X', 'X', null, null, 'O', null, null, null, null], rng), 2);
      expect(ticTacToeResult(['X', 'X', 'X', null, null, null, null, null, null]), 'X');
      expect(ticTacToeResult(['X', 'O', 'X', 'X', 'O', 'O', 'O', 'X', 'X']), 'draw');
      expect(ticTacToeResult(List.filled(9, null)), isNull);
    });
  });

  group("Sync's own chats", () {
    testWidgets('saved messages and the service chat are named and marked', (tester) async {
      await _pump(tester, _shotWrap(const ShellScreen()));
      expect(find.text(tr('saved_messages')), findsOneWidget);
      // Its name is also the app's name, so the icons are what pin it down.
      expect(find.text(tr('service_chat')), findsWidgets);
      // The mark belongs to Sync's chat alone, and there is exactly one of them.
      expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
      expect(find.byIcon(Icons.campaign_rounded), findsOneWidget);
    });

    testWidgets('the service chat shows Sync wording and takes no messages', (tester) async {
      await _pump(tester, _shotWrap(const ChatScreen(chatId: FakeBackend.serviceId)));
      // The words come from the app, so the sign-in notice reads in the reader's
      // language and the raw name from the wire is never shown.
      expect(find.textContaining(tr('service_new_device')), findsOneWidget);
      expect(find.text('new_device'), findsNothing);
      // The place the gateway reported is kept.
      expect(find.textContaining('84.54.1.9'), findsOneWidget);
      expect(find.textContaining(tr('service_welcome')), findsOneWidget);
      // Nothing can be written here.
      expect(find.text(tr('service_read_only')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('saved messages can be written to', (tester) async {
      await _pump(tester, _shotWrap(const ChatScreen(chatId: FakeBackend.savedId)));
      expect(find.text(tr('service_read_only')), findsNothing);
      expect(find.byType(TextField), findsWidgets);
    });

    testWidgets('details open for both without a peer to read', (tester) async {
      // Tapping the header used to reach code that assumed a person on the other
      // side, and there is none in either of these chats.
      for (final id in [FakeBackend.savedId, FakeBackend.serviceId]) {
        await _pump(tester, _shotWrap(ChatInfoScreen(chatId: id)));
        expect(tester.takeException(), isNull);
        expect(find.text(tr('service_read_only')), findsNothing);
      }
    });

    test('an unknown notice is explained, never shown raw', () {
      final m = Message({
        'id': 'x',
        'chat_id': 'service',
        'sender': 'service',
        'kind': 'service',
        'content': {'service': 'something_a_newer_gateway_sends'},
        'ts': 0,
      });
      expect(m.serviceText, tr('service_unknown'));
      expect(m.serviceText.contains('something_a_newer_gateway_sends'), isFalse);
    });

    test('only the service chat is marked verified, and only it is read-only', () {
      Chat of(String type) => Chat({'id': type, 'type': type, 'state': 'active'});
      expect(of('service').isVerified, isTrue);
      expect(of('service').readOnly, isTrue);
      expect(of('saved').isVerified, isFalse);
      expect(of('saved').readOnly, isFalse);
      expect(of('direct').isVerified, isFalse);
      expect(of('group').isVerified, isFalse);
      // A peer cannot hand over a title, a type or a mark for these: the core sets
      // the type from its own tables. A chat merely called "Sync" is not marked.
      final impostor = Chat({'id': 'u:abc', 'type': 'direct', 'title': 'Sync', 'state': 'active'});
      expect(impostor.isVerified, isFalse);
      expect(impostor.title, 'Sync');
    });
  });

  group('sign-up through the bot', () {
    testWidgets('the first screen offers Telegram, not a phone number', (tester) async {
      await _pump(tester, _shotWrap(const OnboardingScreen()));
      expect(find.text(tr('tg_continue')), findsOneWidget);
      expect(find.text(tr('get_sms_code')), findsNothing);
    });

    testWidgets('a gateway with no bot falls back to the phone screen', (tester) async {
      final fake = FakeBackend()..botDisabled = true;
      await _pump(tester, _shotWrap(const OnboardingScreen()), backend: fake);
      await tester.tap(find.text(tr('tg_continue')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 1));
      // The paid paths are still reachable, so a gateway without a bot still works.
      expect(find.text(tr('tg_continue')), findsNothing);
      expect(find.text(tr('get_sms_code')), findsOneWidget);
    });

    test('a refused ticket throws instead of looking accepted', () async {
      final fake = FakeBackend();
      final state = AppState(fake);
      addTearDown(state.dispose);
      final pending = state.submitTicket('t' * 32);
      await pumpEventQueue();
      fake.push({'@type': 'updateConnection', 'state': 'unverified', 'reason': 'invalid_ticket'});
      await expectLater(pending, throwsA(predicate((e) => '$e'.contains('invalid_ticket'))));
    });

    test('an accepted ticket resolves once the gateway says ready', () async {
      final fake = FakeBackend();
      final state = AppState(fake);
      addTearDown(state.dispose);
      final pending = state.submitTicket('t' * 32);
      await pumpEventQueue();
      fake.push({'@type': 'updateConnection', 'state': 'ready'});
      await pending;
      expect(fake.calls.any((c) => c['@type'] == 'setAuthTicket' && c['ticket'] == 't' * 32), isTrue);
    });

    test('polling reports nothing until the bot has proved a number', () async {
      final fake = FakeBackend();
      final state = AppState(fake);
      addTearDown(state.dispose);
      expect(await state.pollTelegramVerify('n' * 32), isNull);
      fake.botTicket = 'z' * 32;
      expect(await state.pollTelegramVerify('n' * 32), 'z' * 32);
    });
  });

  group('sign-up', () {
    test('a refused code throws instead of looking accepted', () async {
      final fake = FakeBackend();
      final state = AppState(fake);
      addTearDown(state.dispose);
      final pending = state.submitCode('+998901234567', '000000');
      await pumpEventQueue();
      fake.push({'@type': 'updateConnection', 'state': 'unverified', 'reason': 'bad_code'});
      await expectLater(pending, throwsA(predicate((e) => '$e'.contains('bad_code'))));
    });

    test('an accepted code resolves once the gateway says ready', () async {
      final fake = FakeBackend();
      final state = AppState(fake);
      addTearDown(state.dispose);
      final pending = state.submitCode('+998901234567', '123456');
      await pumpEventQueue();
      fake.push({'@type': 'updateConnection', 'state': 'ready'});
      await pending;
      expect(fake.calls.any((c) => c['@type'] == 'setAuthCode' && c['code'] == '123456'), isTrue);
    });

    testWidgets('the sign-up button works even with no live connection', (tester) async {
      // It makes an HTTP call, not a socket one. Gating it on the socket left the
      // only button on the screen dead whenever the gateway blinked.
      final fake = FakeBackend();
      await _pump(tester, _shotWrap(const OnboardingScreen()), backend: fake);
      fake.push({'@type': 'updateConnection', 'state': 'offline'});
      // The update arrives on a stream, so the event queue has to drain first.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
      final button = find.widgetWithText(GlassButton, tr('tg_continue'));
      expect(button, findsOneWidget);
      expect(tester.widget<GlassButton>(button).onTap, isNotNull);
      // And it says why nothing is moving, instead of a dead button saying nothing.
      expect(find.text(tr('connecting')), findsOneWidget);
    });

    test('a code can be asked for while the account is still unverified', () async {
      final fake = FakeBackend();
      final state = AppState(fake);
      addTearDown(state.dispose);
      await pumpEventQueue();
      fake.push({'@type': 'updateConnection', 'state': 'offline'});
      await pumpEventQueue();
      expect(state.canRequestCode, isFalse);
      // The gateway refuses an unregistered account, so this is the state the
      // phone screen actually sits in; its button must not be disabled.
      fake.push({'@type': 'updateConnection', 'state': 'unverified', 'reason': 'verification_required'});
      await pumpEventQueue();
      expect(state.canRequestCode, isTrue);
      expect(state.online, isFalse);
    });
  });
}

class _FailingAi extends FakeBackend {
  @override
  Future<Map<String, dynamic>> call(String type, [Map<String, dynamic> params = const {}]) {
    if (type == 'askAi') return Future.error(Exception('ai_failed'));
    return super.call(type, params);
  }
}
