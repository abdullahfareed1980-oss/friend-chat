import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// ---------------------------------------------------------------------------
/// Notifications without FCM or APNs.
///
/// There is no push provider in this app. The foreground service keeps the
/// socket alive, the socket receives the message, and this class raises a
/// *local* notification on the device. Nothing about the notification ever
/// passes through Google or Apple servers.
/// ---------------------------------------------------------------------------

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Set by the app so a tap can open the chat.
  void Function(String? payload)? onTap;

  static const _messageChannel = AndroidNotificationDetails(
    'friend_chat_messages_v1',
    'Messages',
    channelDescription: 'New messages from your Friend Chat contact',
    importance: Importance.high,
    priority: Priority.high,
    color: Color(0xFF6366F1),
    category: AndroidNotificationCategory.message,
  );

  Future<void> initialize() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: darwinInit, macOS: darwinInit),
      onDidReceiveNotificationResponse: (response) => onTap?.call(response.payload),
    );

    if (Platform.isAndroid) {
      final android =
          _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        'friend_chat_messages_v1',
        'Messages',
        description: 'New messages from your Friend Chat contact',
        importance: Importance.high,
      ));
      await android?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  Future<void> showMessage({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) return;
    try {
      await _plugin.show(
        DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
        title,
        body,
        const NotificationDetails(android: _messageChannel, iOS: DarwinNotificationDetails()),
        payload: payload,
      );
    } catch (err) {
      debugPrint('notification failed: $err');
    }
  }

  Future<void> showServiceState({required String text}) async {
    if (!_initialized || !Platform.isAndroid) return;
    await _plugin.show(
      1001,
      'Friend Chat',
      text,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'friend_chat_service_v1',
          'Connection status',
          channelDescription: 'Keeps the private connection alive',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          onlyAlertOnce: true,
        ),
      ),
    );
  }

  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }
}
