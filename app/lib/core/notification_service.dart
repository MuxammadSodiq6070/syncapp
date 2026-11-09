import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Handles local notifications (foreground messages, missed calls, etc.)
/// For background FCM push, wire up firebase_messaging in main.dart.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  // Notification channel IDs
  static const _msgChannelId = 'sync_messages';
  static const _callChannelId = 'sync_calls';
  static const _generalChannelId = 'sync_general';

  /// Call once at app startup (before runApp or in main.dart)
  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(android: android, iOS: ios);

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onTap,
    );

    // Create Android notification channels
    if (Platform.isAndroid) {
      await _createChannels();
    }
  }

  Future<void> _createChannels() async {
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return;

    await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
      _msgChannelId,
      'Messages',
      description: 'New message notifications',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    ));

    await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
      _callChannelId,
      'Calls',
      description: 'Incoming call notifications',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    ));

    await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
      _generalChannelId,
      'General',
      description: 'General notifications',
      importance: Importance.defaultImportance,
    ));
  }

  void _onTap(NotificationResponse response) {
    // Handle notification tap — navigate to chat etc.
    debugPrint('Notification tapped: ${response.payload}');
  }

  /// Show a new message notification
  Future<void> showMessageNotification({
    required int id,
    required String senderName,
    required String body,
    String? chatId,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _msgChannelId,
      'Messages',
      channelDescription: 'New message notifications',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      ticker: 'New message',
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _plugin.show(
      id,
      senderName,
      body,
      details,
      payload: chatId,
    );
  }

  /// Show incoming call notification (heads-up style)
  Future<void> showIncomingCallNotification({
    required String callerName,
    required String callId,
    required bool isVideo,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      _callChannelId,
      'Calls',
      channelDescription: 'Incoming call notifications',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true, // Show full-screen on Android
      ticker: 'Incoming ${isVideo ? 'video' : 'audio'} call',
      icon: '@mipmap/ic_launcher',
      actions: const [
        AndroidNotificationAction('accept', 'Accept', showsUserInterface: true),
        AndroidNotificationAction('decline', 'Decline'),
      ],
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _plugin.show(
      callId.hashCode,
      '${isVideo ? '📹' : '📞'} $callerName',
      isVideo ? 'Incoming video call...' : 'Incoming audio call...',
      details,
      payload: 'call:$callId',
    );
  }

  /// Cancel a specific notification
  Future<void> cancel(int id) => _plugin.cancel(id);

  /// Cancel all notifications
  Future<void> cancelAll() => _plugin.cancelAll();
}
