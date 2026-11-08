// Exercises the real path: Dart -> FFI -> sync_core -> gateway -> sync_core -> Dart.
// Needs SYNC_CORE_LIB=/path/libsync_core.so and SYNC_TEST_GATEWAY=ws://host:port.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_app/core/app_state.dart';
import 'package:sync_app/core/backend.dart';

String _hexKey() {
  final r = Random.secure();
  return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

Future<void> _until(bool Function() test, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final gateway = Platform.environment['SYNC_TEST_GATEWAY'];
  final skip = gateway == null || Platform.environment['SYNC_CORE_LIB'] == null;

  test(
    'two clients chat through the real core and gateway',
    () async {
      final root = await Directory.systemTemp.createTemp('sync_native');
      Future<AppState> client(String name) async {
        final dir = await Directory('${root.path}/$name').create();
        final b = await NativeBackend.start(dataDir: dir.path, localKeyHex: _hexKey(), gatewayUrl: gateway!);
        final s = AppState(b);
        await _until(() => s.loaded && s.online, '$name connected');
        return s;
      }

      final tag = _hexKey().substring(0, 8);
      final a = await client('a'), b = await client('b');
      addTearDown(() {
        a.dispose();
        b.dispose();
      });
      expect(a.needsProfile, isTrue);
      await a.setProfile('a_$tag', 'Aziza');
      await b.setProfile('b_$tag', 'Bekzod');
      await _until(() => !a.needsProfile && !b.needsProfile, 'profiles');
      expect(a.needsProfile, isFalse);

      expect(
        () => b.setProfile('a_$tag', 'Bekzod'),
        throwsA(isA<SyncError>().having((e) => e.code, 'code', 'username_taken')),
      );

      final found = await a.searchUsers('b_$tag');
      expect(found.single.displayName, 'Bekzod');
      final chat = await a.openDirect(found.single.id);
      await a.loadThread(chat.id);
      await a.sendText(chat.id, 'Salom 👋');

      await _until(() => b.requests.isNotEmpty, 'request at b');
      final incoming = b.requests.single;
      expect(incoming.unread, 1);
      expect(incoming.lastMessage!.text, 'Salom 👋');
      expect(a.thread(chat.id).single.text, 'Salom 👋');

      await b.acceptRequest(incoming.id);
      await b.markRead(incoming.id);
      await _until(() => a.thread(chat.id).single.status == 'read', 'read receipt');

      // Kv is sealed locally and round-trips JSON.
      await a.setKv('demo', {
        'x': [1, 2],
      });
      expect(await a.getKv('demo'), {
        'x': [1, 2],
      });
      expect(await a.getKv('missing'), isNull);

      // Marketplace goes through the core's relay.
      await a.postListing('Velosiped $tag', '100\$', 'yangi', 'Vehicles');
      final items = await b.listings(tag);
      expect(items.single['seller_name'], 'Aziza');

      // No API key on the test gateway: the feature says so rather than hanging.
      await expectLater(
        a.askAi([
          {'role': 'user', 'text': 'hi'},
        ], ''),
        throwsA(isA<SyncError>().having((e) => e.code, 'code', 'ai_not_configured')),
      );

      await root.delete(recursive: true);
    },
    skip: skip ? 'set SYNC_CORE_LIB and SYNC_TEST_GATEWAY' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
