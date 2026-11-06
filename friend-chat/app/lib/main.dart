import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'services/notifications.dart';
import 'state/app_session.dart';

/// Friend Chat entry point.
///
/// Startup order matters:
///   1. bind the framework
///   2. initialise *local* notifications (no push provider is contacted)
///   3. create the session and let the app bootstrap it
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  await NotificationService.instance.initialize();

  final session = AppSession();
  runApp(FriendChatApp(session: session));

  // Reconnection watchdog: if the OS kills the socket while we are alive,
  // re-race endpoints (Wi-Fi -> mobile data) and reconnect.
  Timer.periodic(const Duration(seconds: 30), (_) {
    if (session.isSignedIn) unawaited(session.reconnect());
  });
}
