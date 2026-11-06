import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'screens/chat_list_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/auto_responder.dart';
import 'services/background_service.dart';
import 'services/notifications.dart';
import 'state/app_session.dart';
import 'state/business_controller.dart';
import 'state/chat_controller.dart';
import 'theme/friend_chat_theme.dart';
import 'widgets/friend_chat_logo.dart';

/// ---------------------------------------------------------------------------
/// Root widget.
///
/// The chat and business controllers are created here - above MaterialApp - so
/// every pushed route (chat, catalog, settings) shares the same live state.
/// ---------------------------------------------------------------------------

class FriendChatApp extends StatefulWidget {
  const FriendChatApp({super.key, required this.session});

  final AppSession session;

  @override
  State<FriendChatApp> createState() => _FriendChatAppState();
}

class _FriendChatAppState extends State<FriendChatApp> with WidgetsBindingObserver {
  final AutoResponder _responder = AutoResponder();

  ChatController? _chat;
  BusinessController? _business;

  bool _foreground = true;
  String? _lastSeenUuid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: FcColors.midnight,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    widget.session.addListener(_onSessionChanged);
    NotificationService.instance.onTap = (_) {};
    unawaited(widget.session.bootstrap());
    _onSessionChanged();
  }

  /// Creates the controllers the moment a session exists, and tears them down
  /// on sign-out.
  void _onSessionChanged() {
    final session = widget.session;

    if (session.status == SessionStatus.signedIn && _chat == null) {
      final chat = ChatController(session: session, autoResponder: _responder);
      final business = BusinessController(
        api: session.api,
        store: session.store,
        autoResponder: _responder,
      );
      chat.addListener(_onChatChanged);
      unawaited(chat.initialize());
      unawaited(business.load());
      unawaited(BackgroundChatService.instance.start());
      _chat = chat;
      _business = business;
      if (mounted) setState(() {});
    } else if (session.status != SessionStatus.signedIn && _chat != null) {
      final oldChat = _chat;
      final oldBusiness = _business;
      _chat = null;
      _business = null;
      if (mounted) setState(() {});
      // Let the tree unmount before disposing what it was listening to.
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        oldChat?.dispose();
        oldBusiness?.dispose();
      });
      unawaited(BackgroundChatService.instance.stop());
    }
  }

  void _onChatChanged() {
    final last = _chat?.lastMessage;
    if (last == null || last.uuid == _lastSeenUuid) return;
    _lastSeenUuid = last.uuid;
    if (last.outgoing || _foreground) return;

    final peer = widget.session.peer?.displayName ?? 'Friend';
    unawaited(
      NotificationService.instance.showMessage(
        title: peer,
        body: last.text ?? (last.isMedia ? 'Sent you an attachment' : 'New message'),
        payload: last.uuid,
      ),
    );
    unawaited(BackgroundChatService.instance.updateStatus('New message from $peer'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !wasForeground) {
      unawaited(_chat?.syncNow());
      unawaited(BackgroundChatService.instance.updateStatus('Private connection active'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_onSessionChanged);
    _chat?.removeListener(_onChatChanged);
    _chat?.dispose();
    _business?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = _chat;
    final business = _business;

    final providers = <SingleChildWidget>[
      ChangeNotifierProvider<AppSession>.value(value: widget.session),
      if (chat != null) ChangeNotifierProvider<ChatController>.value(value: chat),
      if (business != null) ChangeNotifierProvider<BusinessController>.value(value: business),
    ];

    return MultiProvider(
      providers: providers,
      child: MaterialApp(
        title: 'Friend Chat',
        debugShowCheckedModeBanner: false,
        theme: buildFriendChatTheme(),
        home: const SessionGate(),
      ),
    );
  }
}

/// Chooses between onboarding and the chats based on the session status.
class SessionGate extends StatelessWidget {
  const SessionGate({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: switch (session.status) {
        SessionStatus.loading => const _Splash(key: ValueKey('splash')),
        SessionStatus.needsServer || SessionStatus.signedOut =>
          const WelcomeScreen(key: ValueKey('welcome')),
        SessionStatus.signedIn => const ChatListScreen(key: ValueKey('chats')),
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FriendChatLogo(size: 104),
            SizedBox(height: 22),
            Text('Friend Chat', style: FcText.display),
            SizedBox(height: 8),
            Text('Unlocking your private line', style: FcText.muted),
            SizedBox(height: 28),
            SizedBox(width: 120, child: LinearProgressIndicator(minHeight: 3)),
          ],
        ),
      ),
    );
  }
}
