import 'package:flutter/material.dart';

import 'localization.dart';

typedef Json = Map<String, dynamic>;

class SyncUser {
  SyncUser(this.raw);
  final Json raw;
  String get id => raw['id'] as String? ?? '';
  String get username => raw['username'] as String? ?? '';
  String get displayName {
    final n = raw['display_name'] as String? ?? '';
    return n.isNotEmpty ? n : (username.isNotEmpty ? username : (id.length > 8 ? id.substring(0, 8) : id));
  }

  bool get blocked => raw['blocked'] as bool? ?? false;
}

class Message {
  Message(this.raw);
  final Json raw;
  String get id => raw['id'] as String;
  String get chatId => raw['chat_id'] as String;
  String get sender => raw['sender'] as String;
  bool get outgoing => raw['outgoing'] as bool? ?? false;
  String get kind => raw['kind'] as String;
  Json get content => (raw['content'] as Map?)?.cast<String, dynamic>() ?? const {};
  String get status => raw['status'] as String? ?? '';
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(raw['ts'] as int);
  int get ts => raw['ts'] as int;
  bool get edited => raw['edited'] as bool? ?? false;
  bool get deleted => raw['deleted'] as bool? ?? false;
  String get text => content['text'] as String? ?? '';

  /// Which notice from Sync this is. The core stores a name, never a sentence.
  String get serviceKey => content['service'] as String? ?? '';

  /// The words for a message from Sync, written here rather than carried over the
  /// wire. That is what stops a hostile gateway from putting a sentence of its own
  /// choosing into the one chat that shows a verified mark.
  String get serviceText {
    switch (serviceKey) {
      case 'welcome':
        return tr('service_welcome');
      case 'new_device':
        final place = content['place'] as String? ?? '';
        final line = tr('service_new_device');
        return place.isEmpty ? line : '$line\n$place';
      default:
        // A newer gateway may send a notice this build does not know. Saying so is
        // better than showing nothing, and better than showing its raw name.
        return tr('service_unknown');
    }
  }
  String? get localPath => content['local_path'] as String?;
  Json? get replyPreview => (raw['reply_preview'] as Map?)?.cast<String, dynamic>();
  List<Json> get reactions =>
      (raw['reactions'] as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
  List<Json> get votes =>
      (raw['votes'] as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();

  /// One-line summary used in the chat list and reply previews.
  String get preview {
    if (deleted) return tr('message_deleted');
    switch (kind) {
      case 'service':
        return serviceText.replaceAll('\n', ' · ');
      case 'image':
        return '📷 Photo';
      case 'poll':
        return '📊 ${content['question'] ?? 'Poll'}';
      case 'file':
        return (content['mime'] as String? ?? '').startsWith('audio/')
            ? '🎤 Voice message'
            : '📄 ${content['name'] ?? 'File'}';
      default:
        return text;
    }
  }
}

class Chat {
  Chat(this.raw);
  final Json raw;
  String get id => raw['id'] as String;
  bool get isGroup => raw['type'] == 'group';

  /// The two chats Sync owns. Their type comes from the core's own tables, never
  /// from a peer, so a stranger cannot make a chat that claims to be either.
  bool get isSaved => raw['type'] == 'saved';
  bool get isService => raw['type'] == 'service';
  bool get isChannel => raw['type'] == 'channel';

  /// Direct chat between two users (not saved messages, service chat, groups, or channels).
  bool get isDirect =>
      !isGroup && !isSaved && !isService && !isChannel && peer != null;

  /// Only Sync's own chat carries the mark, and only because of its reserved type.
  bool get isVerified => isService;

  /// Sync writes here; nobody writes back.
  bool get readOnly => isService;

  IconData? get icon => isSaved
      ? Icons.bookmark_rounded
      : isService
      // Not the verified mark: that sits beside the name as a badge, and using it
      // twice reads as decoration instead of as a claim about who is writing.
      ? Icons.campaign_rounded
      : null;

  /// The person's own id for direct chats, so their colour matches everywhere.
  String get avatarId => peer?.id ?? id;
  String get title {
    final stored = raw['title'] as String? ?? '';
    if (stored.isNotEmpty) return stored;
    // Sync's own chats are named by the app, so the name is in whatever language the
    // reader has chosen rather than the one that happened to be set when it was made.
    if (isSaved) return tr('saved_messages');
    if (isService) return tr('service_chat');
    return stored;
  }
  String get admin => raw['admin'] as String? ?? '';
  String get state => raw['state'] as String? ?? 'active';
  bool get archived => raw['archived'] as bool? ?? false;
  bool get muted => raw['muted'] as bool? ?? false;
  int get unread => raw['unread'] as int? ?? 0;
  int get updatedAt => raw['updated_at'] as int? ?? 0;
  bool get isRequest => state == 'request';
  bool get hasLeft => state == 'left';
  SyncUser? get peer => raw['peer'] == null ? null : SyncUser((raw['peer'] as Map).cast<String, dynamic>());
  List<SyncUser> get members =>
      (raw['members'] as List? ?? const []).cast<Map>().map((e) => SyncUser(e.cast<String, dynamic>())).toList();
  Message? get lastMessage =>
      raw['last_message'] == null ? null : Message((raw['last_message'] as Map).cast<String, dynamic>());
}

class Story {
  Story(this.raw);
  final Json raw;
  String get id => raw['id'] as String;
  SyncUser get sender => SyncUser((raw['sender'] as Map).cast<String, dynamic>());
  Json get content => (raw['content'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool get isText => content['kind'] == 'text';
  String get text => content['text'] as String? ?? '';
  int get color => content['color'] as int? ?? 0;
  String? get localPath => content['local_path'] as String?;
  String get caption => content['caption'] as String? ?? '';
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(raw['ts'] as int);
  bool get seen => raw['seen'] as bool? ?? false;
}

class Presence {
  const Presence(this.online, this.lastSeen);
  final bool online;
  final int lastSeen;
}

/// Every story from one person, oldest first.
class StoryGroup {
  StoryGroup(this.user, this.stories);
  final SyncUser user;
  final List<Story> stories;
  bool get allSeen => stories.every((s) => s.seen);
}
