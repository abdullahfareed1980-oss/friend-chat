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
    required this.expiresInSeconds,
    required this.resendAfterSeconds,
    required this.known,
    this.devCode,
  });

  final String challengeId;
  final String phone;
  final String countryCode;
  final int expiresInSeconds;
  final int resendAfterSeconds;
  final bool known;

  /// Only present when the server runs with OTP_DEBUG=true.
  final String? devCode;

  factory OtpChallenge.fromJson(Map<String, dynamic> json) => OtpChallenge(
        challengeId: json['challengeId'] as String,
        phone: (json['phone'] ?? '') as String,
        countryCode: (json['countryCode'] ?? '') as String,
        expiresInSeconds: (json['expiresInSeconds'] ?? 600) as int,
        resendAfterSeconds: (json['resendAfterSeconds'] ?? 60) as int,
        known: json['known'] == true,
        devCode: json['devCode'] as String?,
      );
}

class SyncPage {
  const SyncPage({required this.messages, required this.latestSeq, required this.hasMore});

  final List<ChatMessage> messages;
  final int latestSeq;
  final bool hasMore;
}

class ApiClient {
  ApiClient({required this.baseUrl, this.token});

  /// HTTP origin, e.g. `http://192.168.1.40:8787`.
  final String baseUrl;
  String? token;

  final _client = http.Client();
  static const _timeout = Duration(seconds: 15);

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
    final res = await _client.get(_uri(path, query), headers: _headers(json: false)).timeout(_timeout);
    return _decode(res);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await _client.post(_uri(path), headers: _headers(), body: jsonEncode(body)).timeout(_timeout);
    return _decode(res);
  }

  Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body) async {
    final res = await _client.put(_uri(path), headers: _headers(), body: jsonEncode(body)).timeout(_timeout);
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

  Future<OtpChallenge> requestOtp({required String countryCode, required String phone}) async {
    final json = await _post('/api/auth/request-otp', {'countryCode': countryCode, 'phone': phone});
    return OtpChallenge.fromJson(json);
  }

  Future<LoginSession> verifyOtp({
    required String challengeId,
    required String code,
    Map<String, dynamic>? device,
  }) async {
    final json = await _post('/api/auth/verify-otp', {
      'challengeId': challengeId,
      'code': code,
      if (device != null) 'device': device,
    });
    return LoginSession.fromJson(json);
  }

  Future<LoginSession> loginWithPassword({
    required String username,
    required String password,
    Map<String, dynamic>? device,
  }) async {
    final json = await _post('/api/auth/login', {
      'username': username,
      'password': password,
      if (device != null) 'device': device,
    });
    return LoginSession.fromJson(json);
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
