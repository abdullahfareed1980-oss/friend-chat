import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/connection_manager.dart';
import '../data/crypto_service.dart';
import '../data/local_store.dart';
import '../data/rest_client.dart';
import '../data/socket_service.dart';
import '../models/models.dart';

enum SessionStatus { loading, needsServer, signedOut, signedIn }

/// ---------------------------------------------------------------------------
/// Owns everything that lives longer than a screen: the saved endpoints, the
/// bearer token, the encryption identity, the encrypted local database and the
/// live socket. Screens never touch these directly, they read state from here.
/// ---------------------------------------------------------------------------

class AppSession extends ChangeNotifier {
  AppSession({LocalStore? store, FlutterSecureStorage? secureStorage})
      : store = store ?? LocalStore.instance,
        _secure = secureStorage ?? const FlutterSecureStorage();

  final LocalStore store;
  final FlutterSecureStorage _secure;
  final CryptoService crypto = CryptoService();
  final SocketService socket = SocketService();

  late final ConnectionManager connection = ConnectionManager(
    loadCandidates: _loadCandidates,
    persistChoice: _persistChoice,
  );

  static const _tokenKey = 'fc_token_v1';
  static const _dbKeyKey = 'fc_db_key_v1';
  static const _deviceIdKey = 'fc_device_id_v1';
  static const _endpointsKey = 'fc_endpoints_v1';
  static const _selectedKey = 'fc_selected_endpoint_v1';

  SessionStatus status = SessionStatus.loading;
  ChatUser? user;
  ChatUser? peer;
  String? conversationId;
  String? token;
  ApiClient? api;
  String? lastError;
  String deviceId = '';
  String deviceName = 'Friend Chat device';
  String devicePlatform = 'unknown';

  List<ChatUser> contacts = const [];
  List<ConversationSummary> conversations = const [];

  List<ServerEndpoint> _endpoints = const [];
  List<ServerEndpoint> get endpoints => _endpoints;

  bool get isSignedIn => status == SessionStatus.signedIn && token != null;
  bool get peerReadyToEncrypt => peer?.identityKey != null && peer!.identityKey!.isNotEmpty;

  /* ------------------------------------------------------------------ */
  /* Boot                                                                */
  /* ------------------------------------------------------------------ */

  Future<void> bootstrap() async {
    status = SessionStatus.loading;
    notifyListeners();

    await _loadDeviceIdentity();
    await crypto.ensureIdentity();
    _endpoints = await _readEndpoints();
    token = await _secure.read(key: _tokenKey);

    if (_endpoints.isEmpty) {
      status = SessionStatus.needsServer;
      notifyListeners();
      return;
    }

    await connection.start();

    if (token == null) {
      status = SessionStatus.signedOut;
      notifyListeners();
      return;
    }

    try {
      final endpoint = await connection.ensureEndpoint();
      if (endpoint == null) throw ApiException(0, 'server_unreachable');
      api = ApiClient(baseUrl: endpoint.httpBase, token: token);
      final session = await api!.me();
      await _adoptSession(session, reconnectSocket: true);
      status = SessionStatus.signedIn;
    } catch (err) {
      // A cached token with an unreachable server still lets the user read
      // their offline history, so we fall back to signed-out only on 401/403.
      if (err is ApiException && err.isAuthFailure) {
        await _secure.delete(key: _tokenKey);
        token = null;
        status = SessionStatus.signedOut;
      } else {
        status = SessionStatus.signedOut;
        lastError = 'Could not reach your server. Check the address in Settings.';
      }
    }
    notifyListeners();
  }

  Future<void> _loadDeviceIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    deviceId = id;
    devicePlatform = Platform.operatingSystem;
    deviceName = await _resolveDeviceName();
    socket.setDevice(id: deviceId, name: deviceName, platform: devicePlatform);
  }

  Future<String> _resolveDeviceName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) return (await info.androidInfo).model;
      if (Platform.isIOS) return (await info.iosInfo).name;
      if (Platform.isWindows) return (await info.windowsInfo).computerName;
      if (Platform.isMacOS) return (await info.macOsInfo).computerName;
      if (Platform.isLinux) return (await info.linuxInfo).prettyName;
    } catch (_) {
      // Permission-free fallback below.
    }
    return Platform.localHostname;
  }

  /* ------------------------------------------------------------------ */
  /* Server endpoints                                                    */
  /* ------------------------------------------------------------------ */

  Future<List<ServerEndpoint>> _loadCandidates() async {
    if (_endpoints.isEmpty) _endpoints = await _readEndpoints();
    return _endpoints;
  }

  Future<void> _persistChoice(ServerEndpoint endpoint) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedKey, endpoint.url);
  }

  Future<List<ServerEndpoint>> _readEndpoints() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_endpointsKey) ?? const [];
    return raw
        .map((entry) {
          final parts = entry.split('|');
          final url = parts.first;
          return ServerEndpoint(url: url, kind: parseEndpointKind(url));
        })
        .toList();
  }

  Future<void> setEndpoints(List<String> urls) async {
    final cleaned = urls
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .map(_normalizeUrl)
        .toSet()
        .toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_endpointsKey, cleaned.map((u) => '$u|${parseEndpointKind(u).name}').toList());
    _endpoints = cleaned.map((u) => ServerEndpoint(url: u, kind: parseEndpointKind(u))).toList();
    notifyListeners();
    if (_endpoints.isNotEmpty) await connection.reRace(reason: 'endpoints updated');
  }

  Future<void> addEndpoint(String url) async {
    await setEndpoints([..._endpoints.map((e) => e.url), url]);
  }

  Future<void> removeEndpoint(String url) async {
    await setEndpoints(_endpoints.where((e) => e.url != url).map((e) => e.url).toList());
  }

  /// API client for the onboarding screens, which run before there is a token.
  Future<ApiClient?> onboardingClient() async {
    await connection.start();
    final endpoint = await connection.ensureEndpoint();
    if (endpoint == null) return null;
    api = ApiClient(baseUrl: endpoint.httpBase, token: token);
    return api;
  }

  /// Probes a candidate before it is saved, so onboarding cannot get stuck.
  Future<Map<String, dynamic>?> testServer(String url) async {
    try {
      return await ApiClient.health(_normalizeUrl(url));
    } catch (_) {
      return null;
    }
  }

  static String _normalizeUrl(String input) {
    var value = input.trim();
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    if (!value.contains(RegExp(r':\d+')) && !value.startsWith('https://')) {
      value = value.replaceAll(RegExp(r'/+$'), '') + ':8787';
    }
    return value.replaceAll(RegExp(r'/+$'), '');
  }

  static EndpointKind parseEndpointKind(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host == 'localhost' || host == '127.0.0.1' || host == '10.0.2.2') return EndpointKind.loopback;
    if (host.startsWith('192.168.') || host.startsWith('10.')) return EndpointKind.lan;
    if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host)) return EndpointKind.lan;
    if (host.startsWith('100.')) return EndpointKind.tailnet; // CGNAT / Tailscale
    if (host.endsWith('.local') || host.endsWith('.lan')) return EndpointKind.lan;
    return EndpointKind.public;
  }

  /* ------------------------------------------------------------------ */
  /* Sign in / out                                                       */
  /* ------------------------------------------------------------------ */

  Future<void> _adoptSession(LoginSession session, {bool reconnectSocket = false}) async {
    token = session.token;
    user = session.user;
    peer = session.peer ?? peer;
    conversationId = session.conversationId ?? conversationId;

    await _secure.write(key: _tokenKey, value: session.token);
    await store.writeMeta('conversationId', conversationId);

    if (!store.isOpen) await _openStore();
    await _publishIdentityKey();

    if (reconnectSocket) unawaited(_connectSocket());
  }

  Future<void> signIn(LoginSession session) async {
    status = SessionStatus.signedIn;
    await _adoptSession(session);
    await _connectSocket();
    await refreshPeer();
    await refreshContacts();
    await refreshConversations();
    notifyListeners();
  }

  Future<void> refreshContacts() async {
    final client = api;
    if (client == null) return;
    try {
      contacts = await client.getContacts();
      notifyListeners();
    } catch (_) {
      // Kept as-is if offline
    }
  }

  Future<void> refreshConversations() async {
    final client = api;
    final me = user;
    if (client == null || me == null) return;
    try {
      conversations = await client.getConversations(me.id);
      notifyListeners();
    } catch (_) {
      // Kept as-is if offline
    }
  }

  Future<String> openConversationWith(ChatUser targetUser) async {
    final client = api;
    if (client == null) throw StateError('Not signed in');
    final res = await client.startConversation(peerId: targetUser.id);
    final conv = res['conversation'] as Map<String, dynamic>;
    final cid = conv['id'] as String;
    conversationId = cid;
    peer = targetUser.copyWith(conversationId: cid);
    await store.writeMeta('conversationId', cid);
    await refreshConversations();
    notifyListeners();
    return cid;
  }

  Future<void> refreshPeer() async {
    final client = api;
    if (client == null) return;
    try {
      final directoryPeer = await client.directoryPeer();
      if (directoryPeer != null) {
        peer = directoryPeer;
        notifyListeners();
      }
    } catch (_) {
      // Keep the cached peer; the safety number screen shows what we know.
    }
  }

  Future<void> _publishIdentityKey() async {
    await crypto.ensureIdentity();
    final key = crypto.identityPublicKeyBase64;
    final client = api;
    if (key == null || client == null) return;
    try {
      await client.publishIdentityKey(key);
    } catch (_) {
      // Retried on the next app start; the app remains usable.
    }
  }

  Future<void> _openStore() async {
    final stored = await _secure.read(key: _dbKeyKey);
    Uint8List key;
    if (stored != null) {
      key = Uint8List.fromList(base64Decode(stored));
    } else {
      final random = Random.secure();
      key = Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
      await _secure.write(key: _dbKeyKey, value: base64Encode(key));
    }
    await store.open(key);
  }

  Future<void> _connectSocket() async {
    final current = token;
    if (current == null) return;
    final endpoint = await connection.ensureEndpoint();
    if (endpoint == null) return;
    api = ApiClient(baseUrl: endpoint.httpBase, token: current);
    await socket.connect(endpoint: endpoint, token: current);
  }

  /// Re-races endpoints and moves the socket when the winner changes.
  Future<void> reconnect() async {
    if (!isSignedIn) return;
    await _connectSocket();
  }

  Future<void> signOut({bool wipe = false}) async {
    await socket.disconnect();
    await _secure.delete(key: _tokenKey);
    if (wipe) {
      await store.clearAll();
      await crypto.destroyIdentity();
    }
    token = null;
    user = null;
    conversationId = null;
    status = SessionStatus.signedOut;
    notifyListeners();
  }

  /// Shown on Settings → Security; both devices must display the same string.
  Future<String?> safetyNumber() async {
    final mine = crypto.identityPublicKeyBase64;
    final theirs = peer?.identityKey;
    if (mine == null || theirs == null || theirs.isEmpty) return null;
    return crypto.safetyNumber(myPublicKeyBase64: mine, peerPublicKeyBase64: theirs);
  }

  @override
  void dispose() {
    unawaited(socket.dispose());
    unawaited(connection.dispose());
    super.dispose();
  }
}
