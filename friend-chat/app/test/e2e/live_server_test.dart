import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:friend_chat/data/rest_client.dart';

/// ---------------------------------------------------------------------------
/// Live-server end-to-end test.
///
/// Unlike the unit tests, this one has no fakes: it spawns the real Node server
/// (`server/src/index.js`) on port 0, seeds the two accounts into a throwaway
/// data directory, then drives it with the same [ApiClient] the app uses. Every
/// request shape and every parsed field below is the contract between
/// `app/lib/data/rest_client.dart` and `server/src/routes.js`, so a rename on
/// either side fails here instead of on someone's phone.
///
/// Message delivery is not covered: sends go over Socket.io, which the Node
/// suite already exercises. This is the REST surface.
///
/// Prerequisites: `node` >= 22.5 on PATH and `server/node_modules` installed
/// (`npm ci`). Without them the file skips — unless FC_E2E_REQUIRED=1, which CI
/// sets so the gate cannot pass by skipping.
/// ---------------------------------------------------------------------------

const _phoneA = '812 3456 7890';
const _phoneB = '812 9876 5432';
const _humanA = 'Hana';
const _humanB = 'Omar';

bool get _required => Platform.environment['FC_E2E_REQUIRED'] == '1';

Directory? _findServerDir() {
  for (final candidate in [
    '${Directory.current.path}/../server',
    '${Directory.current.path}/server',
  ]) {
    final packageJson = File('$candidate/package.json');
    if (packageJson.existsSync()) return Directory(packageJson.parent.path).absolute;
  }
  return null;
}

String? _prerequisiteProblem() {
  final serverDir = _findServerDir();
  if (serverDir == null) return 'could not find friend-chat/server next to the app folder';
  if (!Directory('${serverDir.path}/node_modules').existsSync()) {
    return 'server/node_modules is missing (run: cd server && npm ci)';
  }
  try {
    final version = Process.runSync('node', ['--version']);
    if (version.exitCode != 0) return 'node --version failed';
    final major = int.tryParse(RegExp(r'v(\d+)').firstMatch('${version.stdout}')?.group(1) ?? '');
    if (major != null && major < 22) return 'node ${version.stdout}'.trim() + ' is too old (needs >= 22.5)';
  } on ProcessException {
    return 'node is not on PATH';
  }
  return null;
}

String _randomKeyBase64() {
  final random = Random.secure();
  return base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
}

void main() {
  // flutter_test installs an HttpOverrides that answers every request with 400
  // so widget tests cannot reach the network. This file talks to a real server
  // on loopback, so the override has to go (no widgets are pumped here).
  HttpOverrides.global = null;

  final problem = _prerequisiteProblem();
  if (problem != null) {
    if (_required) {
      test('live-server E2E prerequisites', () => fail(problem));
    } else {
      test('live-server E2E skipped: $problem', () {});
    }
    return;
  }

  final serverDir = _findServerDir()!;
  const dataDirPrefix = 'friend-chat-e2e-';

  late Directory dataDir;
  late Process server;
  late String baseUrl;
  final serverLog = <String>[];

  late ApiClient alice;
  late ApiClient bob;
  late LoginSession aliceSession;
  late LoginSession bobSession;
  late OtpChallenge aliceChallenge;

  final baseEnv = {
    'DATA_DIR': '',
    'NODE_ENV': 'test',
    'LOG_LEVEL': 'warn',
    'OTP_DEBUG': 'true',
    'OTP_TTL_SECONDS': '600',
    'OTP_RESEND_SECONDS': '60',
  };

  /// One parser for the banner line: `listening     http://0.0.0.0:41234`.
  final portLine = RegExp(r'listening\s+http://[^:\s]+:(\d+)');

  setUpAll(() async {
    dataDir = Directory.systemTemp.createTempSync(dataDirPrefix);
    baseEnv['DATA_DIR'] = dataDir.path;

    final seeded = Process.runSync(
      'node',
      ['src/seed.js'],
      workingDirectory: serverDir.path,
      environment: {
        ...baseEnv,
        'SEED_USER_A_PASSWORD': 'hana-e2e-password-1',
        'SEED_USER_B_PASSWORD': 'omar-e2e-password-2',
        'SEED_USER_A_PHONE': '+62 $_phoneA',
        'SEED_USER_B_PHONE': '+62 $_phoneB',
      },
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (seeded.exitCode != 0) {
      throw StateError('seed failed (${seeded.exitCode}):\n${seeded.stdout}\n${seeded.stderr}');
    }

    server = await Process.start(
      'node',
      ['src/index.js'],
      workingDirectory: serverDir.path,
      environment: {...baseEnv, 'PORT': '0'},
    );

    final ready = Completer<String>();
    void pump(String line) {
      serverLog.add(line);
      final match = portLine.firstMatch(line);
      if (match != null && !ready.isCompleted) ready.complete('http://127.0.0.1:${match.group(1)}');
    }

    server.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(pump);
    server.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(serverLog.add);
    unawaited(server.exitCode.then((code) {
      if (!ready.isCompleted) ready.completeError(StateError('server exited early ($code)'));
    }));

    baseUrl = await ready.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () => throw StateError('server never announced a port:\n${serverLog.join('\n')}'),
    );

    alice = ApiClient(baseUrl: baseUrl);
    bob = ApiClient(baseUrl: baseUrl);
  });

  tearDownAll(() async {
    alice.close();
    bob.close();
    server.kill(ProcessSignal.sigterm);
    await server.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      server.kill(ProcessSignal.sigkill);
      return server.exitCode;
    });
    try {
      dataDir.deleteSync(recursive: true);
    } on FileSystemException {
      // A leftover temp directory is not worth failing a green run.
    }
  });

  /// The onboarding flow exactly as `OnboardingScreen` performs it.
  Future<LoginSession> signIn(ApiClient client, String phone) async {
    final challenge = await client.requestOtp(countryCode: '+62', phone: phone);
    expect(challenge.known, isTrue, reason: 'both numbers were just seeded');
    expect(challenge.devCode, isNotNull, reason: 'the server must run with OTP_DEBUG=true');
    final res = await client.verifyOtp(challengeId: challenge.challengeId, code: challenge.devCode!);
    final session = res.session!;
    client.token = session.token;
    return session;
  }

  // These tests share the server and run in declaration order, like a session.
  group('live server', () {
    test('health describes an enrolled two-person server', () async {
      final health = await ApiClient.health(baseUrl);

      expect(health['ok'], isTrue);
      expect(health['e2ee'], isTrue);
      expect(health['users'], 2);
      expect(health['maxUsers'], 2);
      expect(health['registrationOpen'], isFalse);
      expect(health['otpDelivery'], 'console');
    });

    test('the first person onboards with phone + OTP', () async {
      aliceChallenge = await alice.requestOtp(countryCode: '+62', phone: _phoneA);

      expect(aliceChallenge.known, isTrue);
      expect(aliceChallenge.phone, '6281234567890');
      expect(aliceChallenge.countryCode, '+62');
      expect(aliceChallenge.expiresInSeconds, 600);
      expect(aliceChallenge.resendAfterSeconds, 60);
      expect(aliceChallenge.devCode, matches(RegExp(r'^\d{6}$')));

      final res = await alice.verifyOtp(
        challengeId: aliceChallenge.challengeId,
        code: aliceChallenge.devCode!,
        device: {'name': 'e2e', 'platform': 'test'},
      );
      aliceSession = res.session!;

      expect(aliceSession.token, isNotEmpty);
      expect(aliceSession.user.displayName, _humanA);
      expect(aliceSession.user.phone, '6281234567890');
      expect(aliceSession.peer?.displayName, _humanB);
      expect(aliceSession.conversationId, isNotNull);

      alice.token = aliceSession.token;
    });

    test('/api/me round-trips the session', () async {
      final me = await alice.me();

      expect(me.user.id, aliceSession.user.id);
      expect(me.user.displayName, _humanA);
      expect(me.peer?.id, aliceSession.peer?.id);
      expect(me.conversationId, aliceSession.conversationId);
      expect(me.token, aliceSession.token);
    });

    test('the second person joins the same conversation', () async {
      bobSession = await signIn(bob, _phoneB);

      expect(bobSession.user.displayName, _humanB);
      expect(bobSession.peer?.displayName, _humanA);
      expect(bobSession.conversationId, aliceSession.conversationId);
      expect(bobSession.user.id, isNot(aliceSession.user.id));
    });

    test('each side sees the other in the directory, without a key yet', () async {
      final peerOfAlice = await alice.directoryPeer();

      expect(peerOfAlice?.id, bobSession.user.id);
      expect(peerOfAlice?.displayName, _humanB);
      expect(peerOfAlice?.hasKey, isFalse);
    });

    test('published identity keys appear in the peer directory', () async {
      final aliceKey = _randomKeyBase64();
      final bobKey = _randomKeyBase64();

      await alice.publishIdentityKey(aliceKey);
      await bob.publishIdentityKey(bobKey);

      expect((await alice.directoryPeer())?.identityKey, bobKey);
      expect((await bob.directoryPeer())?.identityKey, aliceKey);
    });

    test('a used or unknown OTP challenge is refused with its own code', () async {
      await expectLater(
        alice.verifyOtp(challengeId: aliceChallenge.challengeId, code: aliceChallenge.devCode!),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'challenge_used')),
      );

      await expectLater(
        bob.requestOtp(countryCode: '+62', phone: '999'), // too short for a phone
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.code, 'code', 'invalid_phone')),
      );
    });

    test('requests without a token are refused', () async {
      final anonymous = ApiClient(baseUrl: baseUrl);
      addTearDown(anonymous.close);

      await expectLater(
        anonymous.sync(sinceSeq: 0, myUserId: 'nobody'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)),
      );
    });

    test('sync answers with an empty first page on a fresh server', () async {
      final page = await alice.sync(sinceSeq: 0, myUserId: aliceSession.user.id);

      expect(page.messages, isEmpty);
      expect(page.latestSeq, 0);
      expect(page.hasMore, isFalse);
    });

    test('business documents round-trip with optimistic concurrency', () async {
      final initial = await alice.businessDoc('quick_replies');
      expect(initial['rev'], 0);
      expect((initial['payload'] as Map)['items'], isEmpty);

      final saved = await alice.putBusinessDoc(
        'quick_replies',
        {
          'items': [
            {'id': 'qr_1', 'title': 'On my way', 'body': 'I am on my way.'},
          ],
        },
        0,
      );
      expect(saved['rev'], 1);

      final reread = await alice.businessDoc('quick_replies');
      expect(reread['rev'], 1);
      final items = (reread['payload'] as Map)['items'] as List;
      expect(items.single, containsPair('title', 'On my way'));

      // Writing against the stale revision must be rejected, not clobbered.
      await expectLater(
        alice.putBusinessDoc('quick_replies', {'items': <dynamic>[]}, 0),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'rev_conflict')),
      );
    });

    test('the peer can read the catalog but not change it', () async {
      await bob.putBusinessDoc(
        'catalog',
        {
          'items': [
            {'id': 'c1', 'name': 'Kopi susu', 'price': 25000, 'currency': 'IDR'},
          ],
        },
        0,
      );

      final catalog = await alice.peerCatalog();
      expect(catalog['ownerId'], bobSession.user.id);
      expect((catalog['items'] as List).single, containsPair('name', 'Kopi susu'));
    });

    test('an unknown document section is a 404', () async {
      await expectLater(
        alice.businessDoc('not_a_section'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.code, 'code', 'unknown_section')),
      );
    });

    test('encrypted media survives upload and download byte for byte', () async {
      final cipherText = Uint8List.fromList(List<int>.generate(4096, (i) => (i * 37) % 256));
      final digest = sha256.convert(cipherText).toString();

      final mediaId = await alice.uploadMedia(
        cipherText: cipherText,
        conversationId: aliceSession.conversationId!,
        sha256Hex: digest,
      );
      expect(mediaId, isNotEmpty);

      expect(await alice.downloadMedia(mediaId), cipherText);
      // The other member of the conversation can fetch the same blob.
      expect(await bob.downloadMedia(mediaId), cipherText);
    });

    test('a checksum mismatch is rejected before anything is stored', () async {
      final cipherText = Uint8List.fromList(utf8.encode('not what the digest says'));

      await expectLater(
        alice.uploadMedia(
          cipherText: cipherText,
          conversationId: aliceSession.conversationId!,
          sha256Hex: sha256.convert(utf8.encode('something else')).toString(),
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.code, 'code', 'checksum_mismatch')),
      );
    });

    test('downloading an unknown media id is a 404', () async {
      await expectLater(
        alice.downloadMedia('00000000-0000-0000-0000-000000000000'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });
}
