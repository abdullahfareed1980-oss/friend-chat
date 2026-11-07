import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:friend_chat/data/crypto_service.dart';

/// The secure-storage mock is process-wide, so a "device" is simulated by
/// resetting the store, then creating a service that generates its identity
/// into it. Earlier services keep their key pair in memory and stay usable.
Future<({CryptoService service, String publicKey})> _newDevice() async {
  FlutterSecureStorage.setMockInitialValues({});
  final service = CryptoService();
  await service.ensureIdentity();
  return (service: service, publicKey: service.identityPublicKeyBase64!);
}

/// Re-encodes an envelope with one ciphertext byte flipped, as a hostile server
/// could do.
String _flipCipherText(String envelopeBase64) {
  final json = Envelope.decode(envelopeBase64);
  final payload = Uint8List.fromList(base64Decode(json['ct'] as String));
  payload[0] ^= 0x01;
  json['ct'] = base64Encode(payload);
  return base64Encode(utf8.encode(jsonEncode(json)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encryptForPeer / decryptFromPeer', () {
    test('round-trips text, including non-ASCII', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      final envelope = await alice.service.encryptForPeer(
        plainText: 'halo, dunia — 🔐 sampai jumpa',
        myUserId: 'u_alice',
        recipientId: 'u_bob',
        recipientPublicKeyBase64: bob.publicKey,
        conversationId: 'c_friend',
      );

      final clear = await bob.service.decryptFromPeer(
        envelopeBase64: envelope,
        myUserId: 'u_bob',
        senderId: 'u_alice',
        conversationId: 'c_friend',
      );

      expect(clear, 'halo, dunia — 🔐 sampai jumpa');
    });

    test('the envelope carries no plaintext and the agreed header', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      final envelope = await alice.service.encryptForPeer(
        plainText: 'secret words',
        myUserId: 'u_alice',
        recipientId: 'u_bob',
        recipientPublicKeyBase64: bob.publicKey,
      );

      expect(envelope, isNot(contains('secret')));
      final json = Envelope.decode(envelope);
      expect(json['v'], 1);
      expect(json['alg'], 'x25519-aesgcm');
      expect(json['from'], 'u_alice');
      // epk is a 32-byte X25519 public key.
      expect(base64Decode(json['epk'] as String), hasLength(32));
      // 12-byte nonce, then ciphertext + 16-byte GCM tag.
      expect(base64Decode(json['n'] as String), hasLength(12));
      expect(base64Decode(json['ct'] as String).length, greaterThan(16));
    });

    test('mints a fresh ephemeral key per message', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      Future<String> epk() async {
        final raw = await alice.service.encryptForPeer(
          plainText: 'same text twice',
          myUserId: 'u_alice',
          recipientId: 'u_bob',
          recipientPublicKeyBase64: bob.publicKey,
        );
        return Envelope.decode(raw)['epk'] as String;
      }

      expect(await epk(), isNot(await epk()));
    });

    test('rejects a tampered ciphertext instead of returning garbage', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      final envelope = await alice.service.encryptForPeer(
        plainText: 'you cannot edit this',
        myUserId: 'u_alice',
        recipientId: 'u_bob',
        recipientPublicKeyBase64: bob.publicKey,
      );

      await expectLater(
        bob.service.decryptFromPeer(
          envelopeBase64: _flipCipherText(envelope),
          myUserId: 'u_bob',
          senderId: 'u_alice',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('binds the key to the claimed sender and conversation', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      final envelope = await alice.service.encryptForPeer(
        plainText: 'direction bound',
        myUserId: 'u_alice',
        recipientId: 'u_bob',
        recipientPublicKeyBase64: bob.publicKey,
        conversationId: 'c_friend',
      );

      // Bob holds the right private key, but HKDF was bound to "u_alice->u_bob".
      // A different claimed sender, or a different conversation, cannot open it.
      await expectLater(
        bob.service.decryptFromPeer(
          envelopeBase64: envelope,
          myUserId: 'u_bob',
          senderId: 'u_mallory',
          conversationId: 'c_friend',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      await expectLater(
        bob.service.decryptFromPeer(
          envelopeBase64: envelope,
          myUserId: 'u_bob',
          senderId: 'u_alice',
          conversationId: 'c_other',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('refuses an unknown algorithm version', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      final envelope = await alice.service.encryptForPeer(
        plainText: 'x',
        myUserId: 'u_alice',
        recipientId: 'u_bob',
        recipientPublicKeyBase64: bob.publicKey,
      );
      final json = Envelope.decode(envelope)..['alg'] = 'rot13';

      await expectLater(
        bob.service.decryptFromPeer(
          envelopeBase64: base64Encode(utf8.encode(jsonEncode(json))),
          myUserId: 'u_bob',
          senderId: 'u_alice',
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('identity', () {
    test('is generated once and reused on the next launch', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final first = CryptoService();
      await first.ensureIdentity();
      final publicKey = first.identityPublicKeyBase64;
      expect(publicKey, isNotNull);

      // A second service over the same store is the next app launch.
      final second = CryptoService();
      await second.ensureIdentity();
      expect(second.identityPublicKeyBase64, publicKey);
    });

    test('destroyIdentity mints a different key', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final service = CryptoService();
      await service.ensureIdentity();
      final before = service.identityPublicKeyBase64;

      await service.destroyIdentity();
      expect(service.identityPublicKeyBase64, isNull);
      await service.ensureIdentity();

      expect(service.identityPublicKeyBase64, isNot(before));
    });

    test('a corrupted stored pair is refused rather than silently replaced', () async {
      final alice = await _newDevice();
      final publicKey = alice.publicKey;

      expect(publicKey, isNotEmpty);

      // A secret that does not match its stored public half.
      FlutterSecureStorage.setMockInitialValues({
        'fc_identity_keypair_v1': jsonEncode({
          'secret': base64Encode(List<int>.filled(32, 7)),
          'public': base64Encode(List<int>.filled(32, 9)),
        }),
      });

      await expectLater(CryptoService().ensureIdentity(), throwsA(isA<StateError>()));
    });
  });

  group('attachments', () {
    test('round-trip arbitrary bytes', () async {
      final service = await _newDevice();
      final clear = Uint8List.fromList(List<int>.generate(4096, (i) => i % 256));

      final sealed = await service.service.encryptAttachment(clear);
      expect(sealed.bytes.length, clear.length + 12 + 16);
      expect(sealed.bytes, isNot(clear));

      final opened = await service.service.decryptAttachment(
        packed: sealed.bytes,
        keyBase64: sealed.keyBase64,
      );
      expect(opened, clear);
    });

    test('a flipped byte fails authentication', () async {
      final service = await _newDevice();
      final sealed = await service.service.encryptAttachment(
        Uint8List.fromList(utf8.encode('photo bytes')),
      );
      final tampered = Uint8List.fromList(sealed.bytes)..[14] ^= 0x01;

      await expectLater(
        service.service.decryptAttachment(packed: tampered, keyBase64: sealed.keyBase64),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('truncated input is rejected before decryption', () async {
      final service = await _newDevice();
      await expectLater(
        service.service.decryptAttachment(
          packed: Uint8List(20),
          keyBase64: base64Encode(List<int>.filled(32, 1)),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('safetyNumber', () {
    test('is symmetric, stable, and formatted as 12 groups', () async {
      final a = await _newDevice();
      final b = await _newDevice();

      final fromA = await a.service.safetyNumber(
        myPublicKeyBase64: a.publicKey,
        peerPublicKeyBase64: b.publicKey,
      );
      final fromB = await b.service.safetyNumber(
        myPublicKeyBase64: b.publicKey,
        peerPublicKeyBase64: a.publicKey,
      );

      expect(fromA, fromB);
      final groups = fromA.split(' ');
      expect(groups, hasLength(12));
      expect(groups.every((g) => g.length == 5 && RegExp(r'^[0-9a-f]+$').hasMatch(g)), isTrue);
    });

    test('changes when the peer key changes', () async {
      final a = await _newDevice();
      final b = await _newDevice();

      final withB = await a.service.safetyNumber(
        myPublicKeyBase64: a.publicKey,
        peerPublicKeyBase64: b.publicKey,
      );
      final withOther = await a.service.safetyNumber(
        myPublicKeyBase64: a.publicKey,
        peerPublicKeyBase64: base64Encode(List<int>.filled(32, 3)),
      );

      expect(withB, isNot(withOther));
    });
  });
}
