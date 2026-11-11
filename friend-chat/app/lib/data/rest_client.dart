import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/models.dart';

/// ---------------------------------------------------------------------------
/// Thin REST client for Friend Chat Server.
///
/// Every call carries the bearer token; nothing is cached by an intermediary
/// (`no-store` on every request) and there is no analytics or error reporting
/// endpoint to leak to.
/// ---------------------------------------------------------------------------

class ApiException implements Exception {
  ApiException(this.statusCode, this.code, [this.detail]);
  final int statusCode;
  final String code;
  final String? detail;

  bool get isAuthFailure => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'ApiException($statusCode, $code${detail == null ? '' : ', $detail'})';
}

class LoginSession {
  const LoginSession({required this.token, required this.user, this.peer, this.conversationId});

  final String token;
  final ChatUser user;
  final ChatUser? peer;
  final String? conversationId;

  factory LoginSession.fromJson(Map<String, dynamic> json) => LoginSession(
        token: json['token'] as String,
        user: ChatUser.fromJson(json['user'] as Map<String, dynamic>),
        peer: json['peer'] != null ? ChatUser.fromJson(json['peer'] as Map<String, dynamic>) : null,
        conversationId: (json['conversation'] as Map<String, dynamic>?)?['id'] as String?,
      );
}

class OtpChallenge {
  const OtpChallenge({
    required this.challengeId,
    required this.phone,
    required this.countryCode,
    this.email,
    required this.expiresInSeconds,
    required this.resendAfterSeconds,
    required this.known,
    this.hasPassword = false,
    this.devCode,
  });

  final String challengeId;
  final String phone;
  final String countryCode;
  final String? email;
  final int expiresInSeconds;
  final int resendAfterSeconds;
  final bool known;
  final bool hasPassword;

  /// Only present when the server runs with OTP_DEBUG=true.
  final String? devCode;

  factory OtpChallenge.fromJson(Map<String, dynamic> json) => OtpChallenge(
        challengeId: json['challengeId'] as String,
        phone: (json['phone'] ?? '') as String,
        countryCode: (json['countryCode'] ?? '') as String,
        email: json['email'] as String?,
        expiresInSeconds: (json['expiresInSeconds'] ?? 600) as int,
        resendAfterSeconds: (json['resendAfterSeconds'] ?? 60) as int,
        known: json['known'] == true,
        hasPassword: json['hasPassword'] == true,
        devCode: json['devCode'] as String?,
      );
}

class VerifyOtpResult {
  const VerifyOtpResult({
    this.session,
    this.needsPassword = false,
    this.requiresPassword = false,
    this.challengeId,
    this.phone,
    this.email,
  });

  final LoginSession? session;
  final bool needsPassword;
  final bool requiresPassword;
  final String? challengeId;
  final String? phone;
  final String? email;

  bool get isSuccess => session != null;
}

class SyncPage {
  const SyncPage({required this.messages, required this.latestSeq, required this.hasMore});

  final List<ChatMessage> messages;
  final int latestSeq;
  final bool hasMore;
}

class ApiClient {
  ApiClient({
    required this.baseUrl,
    this.token,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  /// HTTP origin, e.g. `http://192.168.1.40:8787`.
  final String baseUrl;
  String? token;

  /// Per-request ceiling for the JSON endpoints. Injectable so a test can
  /// prove a hung server surfaces as [TimeoutException] without waiting 15s.
  final Duration timeout;

  final http.Client _client;

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'content-type': 'application/json',
        'cache-control': 'no-store',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<Map<String, dynamic>> _decode(http.Response res) async {
    final body = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, (body['error'] ?? 'http_${res.statusCode}') as String,
          body['hint'] as String?);
    }
    return body;
  }

  Future<Map<String, dynamic>> _get(String path, {Map<String, String>? query}) async {
    final res = await _client.get(_uri(path, query), headers: _headers(json: false)).timeout(timeout);
    return _decode(res);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await _client.post(_uri(path), headers: _headers(), body: jsonEncode(body)).timeout(timeout);
    return _decode(res);
  }

  Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body) async {
    final res = await _client.put(_uri(path), headers: _headers(), body: jsonEncode(body)).timeout(timeout);
    return _decode(res);
  }

  /* ------------------------------------------------------------------ */
  /* Onboarding                                                          */
  /* ------------------------------------------------------------------ */

  static Future<Map<String, dynamic>> health(String baseUrl) async {
    final client = http.Client();
    try {
      final res = await client
          .get(Uri.parse('$baseUrl/api/health'), headers: {'cache-control': 'no-store'})
          .timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) throw ApiException(res.statusCode, 'unhealthy');
      return jsonDecode(res.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<OtpChallenge> requestOtp({
    required String countryCode,
    required String phone,
    String? email,
  }) async {
    final json = await _post('/api/auth/request-otp', {
      'countryCode': countryCode,
      'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email.trim().toLowerCase(),
    });
    return OtpChallenge.fromJson(json);
  }

  Future<VerifyOtpResult> verifyOtp({
    required String challengeId,
    required String code,
    String? password,
    String? displayName,
    Map<String, dynamic>? device,
  }) async {
    final json = await _post('/api/auth/verify-otp', {
      'challengeId': challengeId,
      'code': code,
      if (password != null) 'password': password,
      if (displayName != null) 'displayName': displayName,
      if (device != null) 'device': device,
    });
    if (json.containsKey('token')) {
      return VerifyOtpResult(session: LoginSession.fromJson(json));
    }
    return VerifyOtpResult(
      needsPassword: json['needsPassword'] == true,
      requiresPassword: json['requiresPassword'] == true,
      challengeId: (json['challengeId'] ?? challengeId) as String?,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
    );
  }

  Future<LoginSession> setPassword({
    required String challengeId,
    required String password,
    String? displayName,
    Map<String, dynamic>? device,
  }) async {
    final json = await _post('/api/auth/set-password', {
      'challengeId': challengeId,
      'password': password,
      if (displayName != null) 'displayName': displayName,
      if (device != null) 'device': device,
    });
    return LoginSession.fromJson(json);
  }

  Future<LoginSession> loginWithPassword({
    String? phone,
    String? countryCode,
    String? email,
    String? username,
    required String password,
    Map<String, dynamic>? device,
  }) async {
    final json = await _post('/api/auth/login', {
      if (phone != null) 'phone': phone,
      if (countryCode != null) 'countryCode': countryCode,
      if (email != null) 'email': email,
      if (username != null) 'username': username,
      'password': password,
      if (device != null) 'device': device,
    });
    return LoginSession.fromJson(json);
  }

  /* ------------------------------------------------------------------ */
  /* Contacts & Conversations Discovery                                 */
  /* ------------------------------------------------------------------ */

  Future<List<ChatUser>> getContacts() async {
    final json = await _get('/api/contacts');
    final list = json['contacts'] as List? ?? [];
    return list.map((item) => ChatUser.fromJson(item as Map<String, dynamic>)).toList();
  }

  Future<List<ConversationSummary>> getConversations(String myUserId) async {
    final json = await _get('/api/conversations');
    final list = json['conversations'] as List? ?? [];
    return list
        .map((item) => ConversationSummary.fromJson(item as Map<String, dynamic>, myUserId: myUserId))
        .toList();
  }

  Future<Map<String, dynamic>> startConversation({String? peerId, String? phone}) async {
    return await _post('/api/conversations', {
      if (peerId != null) 'peerId': peerId,
      if (phone != null) 'phone': phone,
    });
  }

  Future<LoginSession> me() async => LoginSession.fromJson({...await _get('/api/me'), 'token': token});

  /* ------------------------------------------------------------------ */
  /* Sync + keys                                                         */
  /* ------------------------------------------------------------------ */

  Future<SyncPage> sync({required int sinceSeq, int limit = 300, required String myUserId}) async {
    final json = await _get('/api/sync', query: {'since': '$sinceSeq', 'limit': '$limit'});
    final messages = (json['messages'] as List)
        .map((m) => ChatMessage.fromWire(m as Map<String, dynamic>, myUserId: myUserId))
        .toList();
    return SyncPage(
      messages: messages,
      latestSeq: (json['latestSeq'] ?? sinceSeq) as int,
      hasMore: json['hasMore'] == true,
    );
  }

  Future<ChatUser?> directoryPeer() async {
    final json = await _get('/api/directory');
    final peer = json['peer'];
    return peer == null ? null : ChatUser.fromJson(peer as Map<String, dynamic>);
  }

  Future<void> publishIdentityKey(String publicKeyBase64) async {
    await _put('/api/me/identity', {'publicKey': publicKeyBase64});
  }

  /* ------------------------------------------------------------------ */
  /* Media                                                               */
  /* ------------------------------------------------------------------ */

  /// Uploads already-encrypted bytes. The server stores and returns ciphertext.
  Future<String> uploadMedia({
    required Uint8List cipherText,
    required String conversationId,
    required String sha256Hex,
  }) async {
    final res = await _client
        .post(
          _uri('/api/media'),
          headers: {
            'content-type': 'application/octet-stream',
            'x-fc-media': jsonEncode({'conversationId': conversationId, 'sha256': sha256Hex}),
            if (token != null) 'authorization': 'Bearer $token',
          },
          body: cipherText,
        )
        .timeout(const Duration(minutes: 2));

    final json = await _decode(res);
    return (json['media'] as Map<String, dynamic>)['id'] as String;
  }

  Future<Uint8List> downloadMedia(String mediaId) async {
    final res = await _client.get(_uri('/api/media/$mediaId'), headers: _headers(json: false)).timeout(
          const Duration(minutes: 2),
        );
    if (res.statusCode >= 400) throw ApiException(res.statusCode, 'media_fetch_failed');
    return res.bodyBytes;
  }

  /* ------------------------------------------------------------------ */
  /* Business documents                                                  */
  /* ------------------------------------------------------------------ */

  Future<Map<String, dynamic>> businessDoc(String section) => _get('/api/business/$section');

  Future<Map<String, dynamic>> putBusinessDoc(String section, Map<String, dynamic> payload, int rev) =>
      _put('/api/business/$section', {'payload': payload, 'rev': rev});

  Future<Map<String, dynamic>> peerCatalog() => _get('/api/business/peer/catalog');

  void close() => _client.close();
}
