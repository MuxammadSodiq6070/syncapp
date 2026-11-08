import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'models.dart';

class AppState extends ChangeNotifier {
  AppState(this.backend) {
    _sub = backend.updates.listen(_onUpdate);
    _bootstrap();
  }

  final SyncBackend backend;
  late final StreamSubscription<Json> _sub;

  SyncUser? me;
  String connection = 'connecting';
  bool loaded = false;
  final Map<String, Chat> _chats = {};
  final Map<String, List<Message>> _threads = {};
  final Map<String, bool> _threadComplete = {};
  final Map<String, Presence> presence = {};
  final Map<String, String> _typing = {};
  final Map<String, Timer> _typingTimers = {};
  List<Story> stories = [];
  String? openChatId;

  bool get online => connection == 'ready';

  /// Whether the gateway can be asked for a sign-up code. An account that does
  /// not exist yet is refused until it presents one, which leaves the core in
  /// `unverified`, so gating this on `online` would disable the very button
  /// that fetches the code.
  bool get canRequestCode => connection == 'ready' || connection == 'unverified';
  bool get needsProfile => me != null && me!.username.isEmpty;

  Future<void> _bootstrap() async {
    final r = await backend('getMe');
    me = SyncUser((r['me'] as Map).cast<String, dynamic>());
    connection = r['state'] as String? ?? connection;
    await refreshChats();
    await refreshStories();
    loaded = true;
    notifyListeners();
  }

  Future<void> refreshChats() async {
    final results = await Future.wait(['main', 'archived', 'requests'].map((f) => backend('getChats', {'filter': f})));
    _chats.clear();
    for (final r in results) {
      for (final c in r['chats'] as List) {
        final chat = Chat((c as Map).cast<String, dynamic>());
        _chats[chat.id] = chat;
      }
    }
    notifyListeners();
  }

  Future<void> refreshStories() async {
    final r = await backend('getStories');
    stories = (r['stories'] as List).map((s) => Story((s as Map).cast<String, dynamic>())).toList();
    notifyListeners();
  }

  void _onUpdate(Json e) {
    switch (e['@type']) {
      case 'updateConnection':
        connection = e['state'] as String;
      case 'updateMe':
        me = SyncUser((e['me'] as Map).cast<String, dynamic>());
      case 'updateChat':
        final chat = Chat((e['chat'] as Map).cast<String, dynamic>());
        _chats[chat.id] = chat;
      case 'updateChatRemoved':
        _chats.remove(e['chat_id']);
        _threads.remove(e['chat_id']);
      case 'updateNewMessage' || 'updateMessage':
        final m = Message((e['message'] as Map).cast<String, dynamic>());
        _upsertMessage(m);
        if (e['@type'] == 'updateNewMessage') {
          _clearTyping(m.chatId);
          if (m.chatId == openChatId) unawaited(markRead(m.chatId));
        }
      case 'updateTyping':
        _setTyping(e['chat_id'] as String, e['user_id'] as String);
      case 'updateUserStatus':
        presence[e['user_id'] as String] = Presence(e['online'] as bool, e['last_seen'] as int? ?? 0);
      case 'updateStories':
        unawaited(refreshStories());
        return;
      default:
        return;
    }
    notifyListeners();
  }

  void _upsertMessage(Message m) {
    final thread = _threads[m.chatId];
    if (thread == null) return; // loaded in full when the chat opens
    final i = thread.indexWhere((x) => x.id == m.id);
    if (i >= 0) {
      thread[i] = m;
    } else {
      thread.insert(0, m);
      thread.sort((a, b) => b.ts.compareTo(a.ts));
    }
  }

  void _setTyping(String chat, String user) {
    _typing[chat] = user;
    _typingTimers[chat]?.cancel();
    _typingTimers[chat] = Timer(const Duration(seconds: 5), () {
      _clearTyping(chat);
      notifyListeners();
    });
  }

  void _clearTyping(String chat) {
    _typing.remove(chat);
    _typingTimers.remove(chat)?.cancel();
  }

  // ---- selectors ---------------------------------------------------------
  List<Chat> _sorted(bool Function(Chat) test) =>
      _chats.values.where(test).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  List<Chat> get mainChats => _sorted((c) => !c.archived && !c.isRequest);
  List<Chat> get archivedChats => _sorted((c) => c.archived && !c.isRequest);
  List<Chat> get requests => _sorted((c) => c.isRequest);
  List<Chat> get friendRequests => _sorted((c) => c.isRequest && !c.isGroup);
  List<Chat> get groups => _sorted((c) => c.isGroup && !c.isRequest && !c.hasLeft);
  List<SyncUser> get contacts =>
      _sorted((c) => !c.isGroup && !c.isRequest)
          .map((c) => c.peer)
          .whereType<SyncUser>()
          .where((u) => !u.blocked)
          .toList();
  Chat? chat(String id) => _chats[id];
  int get unreadChats => mainChats.where((c) => c.unread > 0 && !c.muted).length;
  String? typingIn(String chatId) => _typing[chatId];
  List<Message> thread(String chatId) => _threads[chatId] ?? const [];
  bool threadComplete(String chatId) => _threadComplete[chatId] ?? false;

  List<StoryGroup> get storyGroups {
    final byUser = <String, List<Story>>{};
    for (final s in stories) {
      (byUser[s.sender.id] ??= []).add(s);
    }
    final groups = byUser.values.map((l) => StoryGroup(l.first.sender, l)).where((g) => g.user.id != me?.id).toList();
    groups.sort((a, b) {
      if (a.allSeen != b.allSeen) return a.allSeen ? 1 : -1;
      return b.stories.last.time.compareTo(a.stories.last.time);
    });
    return groups;
  }

  StoryGroup? get myStories {
    final mine = stories.where((s) => s.sender.id == me?.id).toList();
    return mine.isEmpty ? null : StoryGroup(mine.first.sender, mine);
  }

  // ---- actions -----------------------------------------------------------
  Future<void> setProfile(String username, String name) async {
    await backend('setProfile', {'username': username, 'display_name': name});
  }

  Future<void> loadThread(String chatId, {bool older = false}) async {
    final existing = _threads[chatId];
    if (older && (existing == null || existing.isEmpty || threadComplete(chatId))) return;
    final r = await backend('getMessages', {'chat_id': chatId, 'limit': 50, if (older) 'before': existing!.last.ts});
    final fetched = (r['messages'] as List).map((m) => Message((m as Map).cast<String, dynamic>())).toList();
    if (older) {
      existing!.addAll(fetched.where((m) => !existing.any((x) => x.id == m.id)));
    } else {
      _threads[chatId] = fetched;
    }
    _threadComplete[chatId] = fetched.length < 50;
    notifyListeners();
  }

  Future<void> markRead(String chatId) => backend('markRead', {'chat_id': chatId});
  Future<void> sendText(String chatId, String text, {String? replyTo}) =>
      backend('sendMessage', {'chat_id': chatId, 'text': text, 'reply_to': ?replyTo});
  Future<void> editMessage(String id, String text) => backend('editMessage', {'message_id': id, 'text': text});
  Future<void> deleteMessage(String id) => backend('deleteMessage', {'message_id': id});
  Future<void> react(String id, String emoji) => backend('react', {'message_id': id, 'emoji': emoji});
  Future<void> vote(String id, int option) => backend('votePoll', {'message_id': id, 'option': option});
  Future<void> downloadMedia(String id) => backend('downloadMedia', {'message_id': id});
  Future<void> sendPoll(String chatId, String q, List<String> options) =>
      backend('sendPoll', {'chat_id': chatId, 'question': q, 'options': options});
  Future<void> sendMedia(String chatId, String path, String kind, String name, String mime, {int w = 0, int h = 0}) =>
      backend('sendMedia', {'chat_id': chatId, 'path': path, 'kind': kind, 'name': name, 'mime': mime, 'w': w, 'h': h});
  void setTyping(String chatId) => unawaited(backend('setTyping', {'chat_id': chatId}).then((_) {}, onError: (_) {}));
  Future<void> setFlag(String chatId, String flag, bool value) =>
      backend('setChatFlag', {'chat_id': chatId, 'flag': flag, 'value': value});
  Future<void> acceptRequest(String chatId) => backend('acceptRequest', {'chat_id': chatId});
  Future<void> deleteChat(String chatId) => backend('deleteChat', {'chat_id': chatId});
  Future<void> setBlocked(String userId, bool blocked) =>
      backend('setBlocked', {'user_id': userId, 'blocked': blocked});

  Future<List<SyncUser>> blockedUsers() async {
    final r = await backend('getBlocked');
    return (r['users'] as List).map((u) => SyncUser((u as Map).cast<String, dynamic>())).toList();
  }

  Future<List<SyncUser>> searchUsers(String q) async {
    final r = await backend('searchUsers', {'query': q});
    return (r['users'] as List).map((u) => SyncUser((u as Map).cast<String, dynamic>())).toList();
  }

  Future<List<Message>> searchMessages(String q) async {
    final r = await backend('searchMessages', {'query': q});
    return (r['messages'] as List).map((m) => Message((m as Map).cast<String, dynamic>())).toList();
  }

  Future<Chat> openDirect(String userId) async {
    final r = await backend('openDirectChat', {'user_id': userId});
    return Chat((r['chat'] as Map).cast<String, dynamic>());
  }

  Future<Chat> createGroup(String title, List<String> members) async {
    final r = await backend('createGroup', {'title': title, 'members': members});
    return Chat((r['chat'] as Map).cast<String, dynamic>());
  }

  Future<void> updateGroup(String chatId, {String? title, List<String>? members}) =>
      backend('updateGroup', {'chat_id': chatId, 'title': ?title, 'members': ?members});
  Future<void> leaveGroup(String chatId) => backend('leaveGroup', {'chat_id': chatId});
  Future<void> postTextStory(String text, int color) => backend('postStory', {'text': text, 'color': color});
  Future<void> postPhotoStory(String path, String caption) => backend('postStory', {'path': path, 'caption': caption});

  void markStorySeen(Story s) {
    if (s.seen) return;
    unawaited(backend('markStorySeen', {'story_id': s.id}).then((_) => refreshStories(), onError: (_) {}));
  }

  Future<String> safetyNumber(String userId) async =>
      (await backend('getSafetyNumber', {'user_id': userId}))['number'] as String;

  /// Asks the gateway to send a sign-up code. Every limit lives on the gateway.
  /// Returns how long to wait before another code may be asked for, and which road
  /// the code took ('telegram' or 'sms') so the screen can say where to look.
  Future<({int retryAfter, String via})> requestSmsCode(String phone) async {
    final r = await backend('requestSmsCode', {'phone': phone});
    return (retryAfter: r['retry_after'] as int? ?? 60, via: r['via'] as String? ?? '');
  }

  /// Hands the gateway the code the person received, which lets the account
  /// register on the next connection.
  Future<void> setAuthCode(String phone, String code) => backend('setAuthCode', {'phone': phone, 'code': code});

  /// Hands over the code and waits for the gateway's verdict.
  Future<void> submitCode(String phone, String code) => _registerWith(() => setAuthCode(phone, code));

  /// Opens a conversation with the Telegram bot. Returns the nonce to poll and the
  /// link to send the person to; the bot is what proves the number, so neither is
  /// a secret the app has to protect.
  Future<({String nonce, String url})> startTelegramVerify() async {
    final r = await backend('startTelegramVerify');
    return (nonce: r['nonce'] as String? ?? '', url: r['url'] as String? ?? '');
  }

  /// Whether the bot has proved a number yet, and the ticket once it has. Null
  /// means "not yet", which is the normal answer and not an error.
  Future<String?> pollTelegramVerify(String nonce) async {
    final r = await backend('pollTelegramVerify', {'nonce': nonce});
    if (r['ready'] != true) return null;
    final ticket = r['ticket'] as String? ?? '';
    return ticket.isEmpty ? null : ticket;
  }

  /// Hands over the bot's proof and waits for the verdict.
  Future<void> submitTicket(String ticket) =>
      _registerWith(() => backend('setAuthTicket', {'ticket': ticket}).then((_) {}));

  /// Hands the gateway whatever proof it asked for and waits for the answer. The
  /// core reconnects to register, so acceptance arrives as `ready` and a refusal as
  /// `unverified` carrying the gateway's reason. Without this wait a refusal would
  /// look accepted and the account would fail to register in silence.
  Future<void> _registerWith(Future<void> Function() hand) async {
    final verdict = Completer<Json>();
    final sub = backend.updates.listen((e) {
      if (e['@type'] != 'updateConnection') return;
      final s = e['state'];
      if ((s == 'ready' || s == 'unverified') && !verdict.isCompleted) verdict.complete(e);
    });
    try {
      await hand();
      final e = await verdict.future.timeout(const Duration(seconds: 45));
      if (e['state'] != 'ready') throw Exception(e['reason'] ?? 'verification_failed');
    } finally {
      await sub.cancel();
    }
  }

  /// Hands the gateway proof of a verified phone number. Only a new account needs
  /// one; the core keeps it in memory for the next connection and no longer.
  Future<void> setAuthToken(String token) => backend('setAuthToken', {'token': token});

  Future<String> recoveryKey() async => (await backend('exportRecoveryKey'))['key'] as String;
  Future<void> importRecoveryKey(String key) => backend('importRecoveryKey', {'key': key});

  Future<dynamic> getKv(String key) async => (await backend('getKv', {'key': key}))['value'];
  Future<void> setKv(String key, Object? value) => backend('setKv', {'key': key, 'value': value});

  Future<List<Json>> listings(String q) async {
    final r = await backend('getListings', {'query': q});
    return (r['items'] as List).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Future<void> postListing(String title, String price, String description, String category) =>
      backend('postListing', {'title': title, 'price': price, 'description': description, 'category': category});
  Future<void> deleteListing(String id) => backend('deleteListing', {'id': id});

  Future<String> askAi(List<Json> turns, String persona) async {
    final r = await backend('askAi', {'turns': turns, 'system': persona});
    return r['text'] as String;
  }

  @override
  void dispose() {
    _sub.cancel();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    backend.dispose();
    super.dispose();
  }
}
