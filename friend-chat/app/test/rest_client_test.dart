import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:friend_chat/data/rest_client.dart';
import 'package:http/http.dart' as http;

/// ---------------------------------------------------------------------------
/// Unit tests for [ApiClient] against a scripted [http.Client].
///
/// `test/e2e/live_server_test.dart` proves the wire contract against the real
/// Node server; this file proves the parts that need no server at all: the
/// headers we promise (`no-store`, bearer, JSON vs octet-stream), the mapping of
/// error bodies to [ApiException], the `TimeoutException` a hung server
/// produces, and the request shapes nothing else in the suite touches.
///
/// `testWidgets` is deliberately avoided: `flutter_test` answers every real
/// socket with 400, and our fake never touches a socket, so plain `test()` is
/// both sufficient and faster.
/// ---------------------------------------------------------------------------

const _baseUrl = 'http://127.0.0.1:9999';

typedef _Handler = Future<http.StreamedResponse> Function(http.Request request);

class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);

  final _Handler _handler;
  final requests = <http.Request>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final req = request as http.Request;
    requests.add(req);
    return _handler(req);
  }

  @override
  void close() => closed = true;
}

http.StreamedResponse _json(Object? body, {int status = 200}) {
  final text = body == null ? '' : jsonEncode(body);
  return http.StreamedResponse(
    Stream.value(Uint8List.fromList(utf8.encode(text))),
    status,
    headers: {'content-type': 'application/json'},
  );
}

ApiClient _client(_FakeClient fake, {String? token, Duration? timeout}) => ApiClient(
      baseUrl: _baseUrl,
      token: token,
      client: fake,
      timeout: timeout ?? const Duration(seconds: 15),
    );

Map<String, dynamic> _user(String id, String name) => {'id': id, 'displayName': name};

void main() {
  group('ApiException', () {
    test('isAuthFailure is true only for 401 and 403', () {
      expect(ApiException(401, 'unauthorized').isAuthFailure, isTrue);
      expect(ApiException(403, 'forbidden').isAuthFailure, isTrue);
      expect(ApiException(400, 'bad_request').isAuthFailure, isFalse);
      expect(ApiException(404, 'not_found').isAuthFailure, isFalse);
      expect(ApiException(500, 'server_error').isAuthFailure, isFalse);
    });

    test('toString includes the detail only when the server sent one', () {
      expect(ApiException(429, 'rate_limited', 'wait 60s').toString(),
          'ApiException(429, rate_limited, wait 60s)');
      expect(ApiException(404, 'not_found').toString(), 'ApiException(404, not_found)');
    });
  });

  group('request shape', () {
    test('a GET carries the token and no-store but no JSON content type', () async {
      final fake = _FakeClient((_) async => _json({'peer': null}));
      await _client(fake, token: 'secret').directoryPeer();

      final req = fake.requests.single;
      expect(req.method, 'GET');
      expect(req.url.toString(), '$_baseUrl/api/directory');
      expect(req.headers['cache-control'], 'no-store');
      expect(req.headers['authorization'], 'Bearer secret');
      expect(req.headers.containsKey('content-type'), isFalse);
      expect(req.body, isEmpty);
    });

    test('a POST sends JSON and omits authorization when signed out', () async {
      final fake = _FakeClient((_) async => _json({'challengeId': 'ch-1'}));
      final challenge = await _client(fake).requestOtp(countryCode: '+62', phone: '8123456');

      final req = fake.requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/api/auth/request-otp');
      expect(req.headers['content-type'], 'application/json');
      expect(req.headers['cache-control'], 'no-store');
      expect(req.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(req.body), {'countryCode': '+62', 'phone': '8123456'});

      expect(challenge.challengeId, 'ch-1');
      expect(challenge.expiresInSeconds, 600, reason: 'server defaults are applied client-side too');
      expect(challenge.resendAfterSeconds, 60);
    });

    test('a PUT sends a JSON body and tolerates an empty 200 response', () async {
      final fake = _FakeClient((_) async => _json(null));
      // Would throw a FormatException if an empty body were fed to jsonDecode.
      await _client(fake, token: 't').publishIdentityKey('PUBLIC_KEY');

      final req = fake.requests.single;
      expect(req.method, 'PUT');
      expect(req.url.path, '/api/me/identity');
      expect(req.headers['authorization'], 'Bearer t');
      expect(jsonDecode(req.body), {'publicKey': 'PUBLIC_KEY'});
    });

    test('query parameters are encoded onto a GET', () async {
      final fake = _FakeClient((_) async => _json({'messages': <dynamic>[], 'latestSeq': 7}));
      await _client(fake).sync(sinceSeq: 3, limit: 50, myUserId: 'me');

      final url = fake.requests.single.url;
      expect(url.path, '/api/sync');
      expect(url.queryParameters, {'since': '3', 'limit': '50'});
    });

    test('the media upload is octet-stream with conversation and digest in x-fc-media', () async {
      final fake = _FakeClient((_) async => _json({'media': {'id': 'media-1'}}));
      final bytes = Uint8List.fromList([1, 2, 3, 250]);

      final id = await _client(fake, token: 'tok').uploadMedia(
        cipherText: bytes,
        conversationId: 'conv-1',
        sha256Hex: 'abc123',
      );

      final req = fake.requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/api/media');
      expect(req.headers['content-type'], 'application/octet-stream');
      expect(req.headers['authorization'], 'Bearer tok');
      expect(jsonDecode(req.headers['x-fc-media']!), {'conversationId': 'conv-1', 'sha256': 'abc123'});
      expect(req.bodyBytes, bytes);
      expect(id, 'media-1');
    });

    test('a media download returns the raw ciphertext bytes', () async {
      final cipher = Uint8List.fromList([9, 8, 7]);
      final fake = _FakeClient(
        (_) async => http.StreamedResponse(Stream.value(cipher), 200),
      );

      expect(await _client(fake).downloadMedia('media-1'), cipher);
      expect(fake.requests.single.url.path, '/api/media/media-1');
      expect(fake.requests.single.headers['cache-control'], 'no-store');
    });

    test('close() closes the underlying client exactly once', () {
      final fake = _FakeClient((_) async => _json(null));
      _client(fake).close();

      expect(fake.closed, isTrue);
    });
  });

  group('error mapping', () {
    test('an error body becomes an ApiException with code and hint', () async {
      final fake = _FakeClient(
        (_) async => _json({'error': 'otp_expired', 'hint': 'request a new code'}, status: 410),
      );

      await expectLater(
        _client(fake).verifyOtp(challengeId: 'c', code: '000000'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 410)
            .having((e) => e.code, 'code', 'otp_expired')
            .having((e) => e.detail, 'detail', 'request a new code')
            .having((e) => e.isAuthFailure, 'isAuthFailure', isFalse)),
      );
    });

    test('an error without a body still carries the HTTP status', () async {
      final fake = _FakeClient((_) async => _json(null, status: 500));

      await expectLater(
        _client(fake).businessDoc('quick_replies'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.code, 'code', 'http_500')
            .having((e) => e.detail, 'detail', isNull)),
      );
    });

    test('a 401 is recognisable as an auth failure by the caller', () async {
      final fake = _FakeClient((_) async => _json({'error': 'token_invalid'}, status: 401));

      await expectLater(
        _client(fake, token: 'stale').me(),
        throwsA(isA<ApiException>().having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)),
      );
    });

    test('a rejected media upload reports the server error, not a null id', () async {
      final fake = _FakeClient((_) async => _json({'error': 'too_large'}, status: 413));

      await expectLater(
        _client(fake).uploadMedia(
          cipherText: Uint8List(4),
          conversationId: 'conv-1',
          sha256Hex: 'digest',
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 413)
            .having((e) => e.code, 'code', 'too_large')),
      );
    });

    test('a failed media download is reported as media_fetch_failed', () async {
      final fake = _FakeClient(
        (_) async => http.StreamedResponse(const Stream<List<int>>.empty(), 404),
      );

      await expectLater(
        _client(fake).downloadMedia('missing'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.code, 'code', 'media_fetch_failed')),
      );
    });
  });

  group('timeouts', () {
    _FakeClient hung() => _FakeClient((_) => Completer<http.StreamedResponse>().future);

    test('a hung GET raises TimeoutException instead of hanging forever', () async {
      await expectLater(
        _client(hung(), timeout: const Duration(milliseconds: 20)).businessDoc('quick_replies'),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a hung POST raises TimeoutException', () async {
      await expectLater(
        _client(hung(), timeout: const Duration(milliseconds: 20)).requestOtp(
          countryCode: '+62',
          phone: '8123456',
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('the default timeout is 15 seconds', () {
      expect(ApiClient(baseUrl: _baseUrl, client: _FakeClient((_) async => _json(null))).timeout,
          const Duration(seconds: 15));
    });
  });

  group('session parsing', () {
    test('password login sends credentials and the optional device block', () async {
      final fake = _FakeClient(
        (_) async => _json({
          'token': 'tok',
          'user': _user('u1', 'Hana'),
          'peer': _user('u2', 'Omar'),
          'conversation': {'id': 'conv-9'},
        }),
      );

      final session = await _client(fake).loginWithPassword(
        username: 'hana',
        password: 'correct horse',
        device: {'name': 'Pixel', 'platform': 'android'},
      );

      final req = fake.requests.single;
      expect(req.url.path, '/api/auth/login');
      expect(jsonDecode(req.body), {
        'username': 'hana',
        'password': 'correct horse',
        'device': {'name': 'Pixel', 'platform': 'android'},
      });
      expect(session.token, 'tok');
      expect(session.user.displayName, 'Hana');
      expect(session.peer?.displayName, 'Omar');
      expect(session.conversationId, 'conv-9');
    });

    test('password login omits the device block when none is given', () async {
      final fake = _FakeClient(
        (_) async => _json({'token': 'tok', 'user': _user('u1', 'Hana')}),
      );

      final session = await _client(fake).loginWithPassword(username: 'hana', password: 'pw');

      expect(jsonDecode(fake.requests.single.body), {'username': 'hana', 'password': 'pw'});
      expect(session.peer, isNull);
      expect(session.conversationId, isNull);
    });

    test('me() injects the bearer token the session was built with', () async {
      final fake = _FakeClient((_) async => _json({'user': _user('u1', 'Hana'), 'peer': _user('u2', 'Omar')}));

      final session = await _client(fake, token: 'stored-token').me();

      expect(session.token, 'stored-token');
      expect(session.user.id, 'u1');
      expect(session.peer?.id, 'u2');
    });

    test('sync falls back to the requested sequence when the server omits latestSeq', () async {
      final fake = _FakeClient((_) async => _json({'messages': <dynamic>[]}));

      final page = await _client(fake).sync(sinceSeq: 42, myUserId: 'me');

      expect(page.messages, isEmpty);
      expect(page.latestSeq, 42);
      expect(page.hasMore, isFalse);
    });

    test('sync reports hasMore when the server has a backlog', () async {
      final fake = _FakeClient((_) async => _json({'messages': <dynamic>[], 'latestSeq': 9, 'hasMore': true}));

      expect((await _client(fake).sync(sinceSeq: 0, myUserId: 'me')).hasMore, isTrue);
    });

    test('directoryPeer returns null until the peer enrolls', () async {
      final fake = _FakeClient((_) async => _json({'peer': null}));

      expect(await _client(fake).directoryPeer(), isNull);
    });

    test('directoryPeer parses the peer once it exists', () async {
      final fake = _FakeClient((_) async => _json({'peer': _user('u2', 'Omar')}));

      final peer = await _client(fake).directoryPeer();
      expect(peer?.id, 'u2');
      expect(peer?.displayName, 'Omar');
    });
  });
}
