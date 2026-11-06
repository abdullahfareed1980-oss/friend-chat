import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// ---------------------------------------------------------------------------
/// Persistent background execution.
///
/// Android: a foreground service with `foregroundServiceType="dataSync"` keeps
/// the process (and therefore the Socket.io connection) alive while the app is
/// in the background. That is what makes socket-based notifications possible
/// without FCM.
///
/// Windows: no service is needed - a desktop app that is minimised keeps its
/// socket. `start()` is a no-op there.
///
/// iOS: the OS will suspend a backgrounded app; there is no supported way to
/// hold a socket open forever without a push provider. The app degrades to
/// "fetch on open", and docs/PLATFORM_SETUP.md explains the trade-off honestly
/// instead of shipping a fake background mode that Apple would reject.
/// ---------------------------------------------------------------------------

class BackgroundChatService {
  BackgroundChatService._();
  static final BackgroundChatService instance = BackgroundChatService._();

  bool _initialized = false;
  bool _running = false;

  bool get isRunning => _running;

  Future<void> initialize() async {
    if (_initialized || !Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'friend_chat_service_v1',
        channelName: 'Connection status',
        channelDescription: 'Keeps your private Friend Chat connection alive',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(15000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    await initialize();

    if (await FlutterForegroundTask.isRunningService) {
      _running = true;
      return true;
    }

    final result = await FlutterForegroundTask.startService(
      serviceId: 4210,
      notificationTitle: 'Friend Chat is connected',
      notificationText: 'Private connection active - no push servers involved',
      notificationIcon: null,
      callback: friendChatTaskCallback,
    );
    _running = result is ServiceRequestSuccess;
    return _running;
  }

  Future<void> updateStatus(String text) async {
    if (!_running) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Friend Chat is connected',
      notificationText: text,
    );
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.stopService();
    _running = false;
  }
}

/// Entry point executed in the service isolate. It deliberately does the bare
/// minimum: hold the process, hold the wake lock, and let the app's main
/// isolate (which owns the socket and the decryption keys) do the work.
@pragma('vm:entry-point')
void friendChatTaskCallback() {
  FlutterForegroundTask.setTaskHandler(FriendChatTaskHandler());
}

class FriendChatTaskHandler extends TaskHandler {
  DateTime? _startedAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _startedAt = timestamp;
    debugPrint('[friend-chat] background service started ($starter)');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // The main isolate owns the socket; this tick only proves the process is
    // alive and lets Android keep the service in the foreground bucket.
    final uptime = _startedAt == null ? 0 : timestamp.difference(_startedAt!).inMinutes;
    if (uptime % 5 == 0) {
      FlutterForegroundTask.saveData(key: 'heartbeat', value: timestamp.toIso8601String());
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[friend-chat] background service stopped');
  }

  @override
  void onReceiveData(Object data) {
    // Commands from the UI isolate (e.g. "pause notifications") land here.
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}
