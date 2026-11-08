import 'dart:async';

import 'package:sync_app/core/backend.dart';

const meId = 'aaaa000000000000000000000000000000000000000000000000000000000001';

String userId(int n) => n.toRadixString(16).padLeft(64, 'b');

Map<String, dynamic> user(int n, String name, String username) => {
  'id': userId(n),
  'display_name': name,
  'username': username,
  'blocked': false,
};

/// In-memory stand-in for sync_core, with fictional demo people.
class FakeBackend implements SyncBackend {
  FakeBackend({DateTime? now}) : now = now ?? DateTime(2026, 11, 6, 16, 34);

  final DateTime now;
  final _updates = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <Map<String, dynamic>>[];
  final kv = <String, Object?>{};
  var profileUsername = 'jamshid';

  /// Set when the gateway has no bot configured, so the app must fall back to the
  /// phone and code screens.
  var botDisabled = false;

  /// The ticket the bot has issued, or null while it has proved nothing yet.
  String? botTicket;

  int _ago(int minutes) => now.subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;

  Map<String, dynamic> msg(
    String id,
    String chat,
    String sender,
    String text,
    int minutesAgo, {
    String status = 'received',
    String kind = 'text',
    Map<String, dynamic>? content,
  }) => {
    'id': id,
    'chat_id': chat,
    'sender': sender,
    'outgoing': sender == meId,
    'kind': kind,
    'content': content ?? {'text': text},
    'status': status,
    'ts': _ago(minutesAgo),
    'edited': false,
    'deleted': false,
    'reactions': <Object>[],
  };

  late final _team = [
    user(1, 'Aziza Karimova', 'aziza'),
    user(2, 'Bekzod Tursunov', 'bekzod'),
    user(3, 'Dilnoza Rahimova', 'dilnoza'),
    user(4, 'Otabek Yusupov', 'otabek'),
  ];

  Map<String, dynamic> _direct(int n, String name, String preview, int minutes, {int unread = 0, bool muted = false}) {
    final u = user(n, name, name.split(' ').first.toLowerCase());
    final id = 'u:${userId(n)}';
    return {
      'id': id,
      'type': 'direct',
      'title': name,
      'admin': '',
      'state': 'active',
      'archived': false,
      'muted': muted,
      'unread': unread,
      'updated_at': _ago(minutes),
      'peer': u,
      'members': [u],
      'last_message': msg('l$n', id, userId(n), preview, minutes),
    };
  }

  static const groupId = 'g:00112233445566778899aabbccddeeff';

  Map<String, dynamic> get group => {
    'id': groupId,
    'type': 'group',
    'title': 'Yoshlar 2.0',
    'admin': meId,
    'state': 'active',
    'archived': false,
    'muted': true,
    'unread': 0,
    'updated_at': _ago(6),
    'members': [
      {'id': meId, 'display_name': 'Jamshid Aliyev', 'username': profileUsername},
      ..._team,
    ],
    'last_message': msg('g-last', groupId, userId(1), 'Bugun uchrashamizmi?', 6),
  };

  /// The two chats Sync owns. The core creates them; the fake states them so the
  /// widget tests see what a real list holds.
  static const savedId = 'saved';
  static const serviceId = 'service';

  Map<String, dynamic> get saved => {
    'id': savedId,
    'type': 'saved',
    'title': '',
    'state': 'active',
    'archived': false,
    'muted': false,
    'unread': 0,
    'updated_at': _ago(1),
    'members': <Object>[],
  };

  late final serviceMessages = [
    {
      'id': 's1',
      'chat_id': serviceId,
      'sender': serviceId,
      'outgoing': false,
      'kind': 'service',
      'content': {'service': 'new_device', 'place': '84.54.1.9'},
      'status': 'received',
      'ts': _ago(3),
      'edited': false,
      'deleted': false,
      'reactions': <Object>[],
    },
    {
      'id': 's0',
      'chat_id': serviceId,
      'sender': serviceId,
      'outgoing': false,
      'kind': 'service',
      'content': {'service': 'welcome'},
      'status': 'received',
      'ts': _ago(9),
      'edited': false,
      'deleted': false,
      'reactions': <Object>[],
    },
  ];

  Map<String, dynamic> get service => {
    'id': serviceId,
    'type': 'service',
    'title': '',
    'state': 'active',
    'archived': false,
    'muted': false,
    'unread': 0,
    'updated_at': _ago(3),
    'members': <Object>[],
    'last_message': serviceMessages.first,
  };

  List<Map<String, dynamic>> get chats => [
    service,
    saved,
    group,
    _direct(1, 'Aziza Karimova', 'Ertaga kutubxonada ko\'rishamiz', 76, unread: 1),
    _direct(2, 'Bekzod Tursunov', 'Loyihani yakunladim, qarab chiqing', 200),
    _direct(3, 'Dilnoza Rahimova', 'Rahmat, juda zo\'r bo\'libdi', 253, unread: 1),
    _direct(4, 'Otabek Yusupov', 'Fayllarni yubordim', 333),
    _direct(5, 'Malika Sodiqova', 'Yaxshi, kelishdik 😄', 333),
    _direct(6, 'Sardor Nazarov', 'Bugun o\'yin bormi? ⚽', 400),
  ];

  List<Map<String, dynamic>> get messages => [
    msg('m4', groupId, userId(1), 'How was your day?', 19),
    msg('m3', groupId, userId(1), "What's up guys?", 19),
    msg('m2', groupId, meId, '👋', 62, status: 'read'),
  ];

  @override
  Stream<Map<String, dynamic>> get updates => _updates.stream;

  void push(Map<String, dynamic> e) => _updates.add(e);

  @override
  Future<Map<String, dynamic>> call(String type, [Map<String, dynamic> params = const {}]) async {
    calls.add({'@type': type, ...params});
    switch (type) {
      case 'getMe':
        return {
          'me': {'id': meId, 'display_name': 'Jamshid Aliyev', 'username': profileUsername},
          'state': 'ready',
        };
      case 'getChats':
        return {'chats': params['filter'] == 'main' ? chats : <Object>[]};
      case 'getStories':
        return {
          'stories': [
            for (final (i, note) in const [
              'Kitob o\'qiyapman 📚',
              'Charchadim 😝',
              'Kechqurun ko\'rishamiz!',
              'Yangi kafe',
            ].indexed)
              {
                'id': 's$i',
                'sender': _team[i],
                'content': {'kind': 'text', 'text': note, 'color': i},
                'ts': _ago(30 + i),
                'seen': false,
              },
          ],
        };
      case 'getMessages':
        return switch (params['chat_id']) {
          groupId => {'messages': messages},
          serviceId => {'messages': serviceMessages},
          _ => {'messages': <Object>[]},
        };
      case 'getKv':
        return {'value': kv[params['key']]};
      case 'setKv':
        kv[params['key'] as String] = params['value'];
        return {};
      case 'getListings':
        return {
          'items': [
            {
              'id': 'x1',
              'seller': userId(2),
              'seller_name': 'Bekzod Tursunov',
              'title': 'Velosiped',
              'price': '1 200 000 so\'m',
              'description': 'Yangi',
              'category': 'Vehicles',
              'created_at': _ago(50),
            },
          ],
        };
      case 'askAi':
        return {'text': 'Salom! Sizga qanday yordam bera olaman?'};
      case 'openDirectChat':
        return {'chat': _direct(9, 'Yangi Odam', '', 0)};
      case 'searchUsers':
        return {'users': <Object>[]};
      case 'searchMessages':
        return {'messages': <Object>[]};
      case 'getBlocked':
        return {'users': <Object>[]};
      case 'startTelegramVerify':
        if (botDisabled) throw Exception('not enabled');
        return {'nonce': 'n' * 32, 'url': 'https://t.me/SyncTestBot?start=${'n' * 32}'};
      case 'pollTelegramVerify':
        return botTicket == null ? {'ready': false, 'ticket': ''} : {'ready': true, 'ticket': botTicket};
      case 'getSafetyNumber':
        return {'number': '12345 67890 12345'};
      case 'exportRecoveryKey':
        return {'key': 'ab' * 32};
      default:
        return {};
    }
  }

  @override
  void dispose() => _updates.close();
}
