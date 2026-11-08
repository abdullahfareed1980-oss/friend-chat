import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ---------------------------------------------------------------------------
/// End-to-end encryption for Friend Chat.
///
/// Scheme (ECIES-style, deliberately simple to audit):
///   1. Each install owns a long-term X25519 key pair. The public half is
///      published to the private server (`PUT /api/me/identity`).
///   2. To send, we mint a *fresh* ephemeral X25519 pair per message, derive a
///      shared secret with the peer's published key, run it through HKDF-SHA256
///      bound to (sender id -> recipient id), and encrypt the JSON payload with
///      AES-256-GCM.
///   3. The envelope that reaches the server is
///      `{v, alg, from, epk, n, ct}` - only the recipient can open it.
///
/// Forward secrecy note: the recipient's static key is reused, so someone who
/// steals the private key later can decrypt old messages. That is the trade-off
/// for a scheme with no server-side ratchet. `docs/SECURITY.md` describes the
/// upgrade path (Double Ratchet / MLS) and what it would cost in complexity.
/// ---------------------------------------------------------------------------

class Envelope {
  const Envelope({required this.from, required this.ephemeralPublicKey, required this.nonce, required this.cipherText});

  final String from;
  final String ephemeralPublicKey;
  final String nonce;
  final String cipherText;

  String encode() => base64Encode(utf8.encode(jsonEncode({
        'v': 1,
        'alg': 'x25519-aesgcm',
        'from': from,
        'epk': ephemeralPublicKey,
        'n': nonce,
        'ct': cipherText,
      })));

  static Map<String, dynamic> decode(String raw) {
    final bytes = base64Decode(raw);
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }
}

class CryptoService {
  CryptoService({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final _x25519 = X25519();
  final _aes = AesGcm.with256bits();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static const _keyPairStoreKey = 'fc_identity_keypair_v1';

  SimpleKeyPair? _identity;
  SimplePublicKey? _identityPublic;

  /// Base64 X25519 public key, published to the server.
  String? get identityPublicKeyBase64 =>
      _identityPublic == null ? null : base64Encode(_identityPublic!.bytes);

  /// Loads the identity key pair, generating it on first launch.
  Future<void> ensureIdentity() async {
    if (_identity != null) return;

    final stored = await _storage.read(key: _keyPairStoreKey);
    if (stored != null) {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      final secret = base64Decode(json['secret'] as String);
      final public = base64Decode(json['public'] as String);
      final pair = SimpleKeyPairData(
        secret,
        publicKey: SimplePublicKey(public, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
      // Re-derive the public half to be certain the stored pair is coherent.
      final derived = await _x25519.newKeyPairFromSeed(secret);
      _identity = derived;
      _identityPublic = await derived.extractPublicKey();
      if (!_bytesEqual(_identityPublic!.bytes, pair.publicKey.bytes)) {
        throw StateError('stored identity key pair is inconsistent');
      }
    } else {
      final pair = await _x25519.newKeyPair();
      _identity = pair;
      _identityPublic = await pair.extractPublicKey();
      await _storage.write(
        key: _keyPairStoreKey,
        value: jsonEncode({
          'secret': base64Encode(await pair.extractPrivateKeyBytes()),
          'public': base64Encode(_identityPublic!.bytes),
        }),
      );
    }
  }

  /// Encrypts [plainText] for [recipientPublicKeyBase64].
  Future<String> encryptForPeer({
    required String plainText,
    required String myUserId,
    required String recipientId,
    required String recipientPublicKeyBase64,
    String? conversationId,
  }) async {
    await ensureIdentity();
    final recipientKey = SimplePublicKey(base64Decode(recipientPublicKeyBase64), type: KeyPairType.x25519);

    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(keyPair: ephemeral, remotePublicKey: recipientKey);

    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('friend-chat/v1/$conversationId'),
      info: utf8.encode('$myUserId->$recipientId'),
    );

    final box = await _aes.encrypt(utf8.encode(plainText), secretKey: key);

    return Envelope(
      from: myUserId,
      ephemeralPublicKey: base64Encode(ephemeralPublic.bytes),
      nonce: base64Encode(box.nonce),
      cipherText: base64Encode([...box.cipherText, ...box.mac.bytes]),
    ).encode();
  }

  /// Opens an envelope addressed to me.
  Future<String> decryptFromPeer({
    required String envelopeBase64,
    required String myUserId,
    required String senderId,
    String? conversationId,
  }) async {
    await ensureIdentity();
    final json = Envelope.decode(envelopeBase64);

    if (json['alg'] != 'x25519-aesgcm') {
      throw UnsupportedError('unknown envelope algorithm ${json['alg']}');
    }

    final ephemeralKey = SimplePublicKey(base64Decode(json['epk'] as String), type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(keyPair: _identity!, remotePublicKey: ephemeralKey);

    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('friend-chat/v1/$conversationId'),
      info: utf8.encode('$senderId->$myUserId'),
    );

    final payload = base64Decode(json['ct'] as String);
    if (payload.length <= 16) throw const FormatException('envelope too short');
    final secretBox = SecretBox(
      payload.sublist(0, payload.length - 16),
      nonce: base64Decode(json['n'] as String),
      mac: Mac(payload.sublist(payload.length - 16)),
    );

    final clear = await _aes.decrypt(secretBox, secretKey: key);
    return utf8.decode(clear);
  }

  /// Encrypts attachment bytes with a one-off key stored inside the message
  /// envelope, so the media blob on the server is unreadable on its own.
  Future<({Uint8List bytes, String keyBase64, String nonceBase64})> encryptAttachment(Uint8List clear) async {
    final key = await _aes.newSecretKey();
    final box = await _aes.encrypt(clear, secretKey: key);
    final packed = Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
    return (
      bytes: packed,
      keyBase64: base64Encode(await key.extractBytes()),
      nonceBase64: base64Encode(box.nonce),
    );
  }

  Future<Uint8List> decryptAttachment({
    required Uint8List packed,
    required String keyBase64,
  }) async {
    if (packed.length <= 12 + 16) throw const FormatException('attachment too short');
    final nonce = packed.sublist(0, 12);
    final body = packed.sublist(12, packed.length - 16);
    final mac = packed.sublist(packed.length - 16);
    final key = SecretKey(base64Decode(keyBase64));
    final clear = await _aes.decrypt(SecretBox(body, nonce: nonce, mac: Mac(mac)), secretKey: key);
    return Uint8List.fromList(clear);
  }

  /// A short human-comparable fingerprint for the Settings → Security screen.
  /// Both phones must show the same 12 groups for the channel to be trusted.
  Future<String> safetyNumber({
    required String myPublicKeyBase64,
    required String peerPublicKeyBase64,
  }) async {
    final sorted = [myPublicKeyBase64, peerPublicKeyBase64]..sort();
    final digest = await Sha256().hash(utf8.encode(sorted.join('|')));
    final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final groups = <String>[];
    for (var i = 0; i < 12; i++) {
      groups.add(hex.substring(i * 5, i * 5 + 5));
    }
    return groups.join(' ');
  }

  /// Wipes the identity. Only reachable from a deliberate "reset this device".
  Future<void> destroyIdentity() async {
    _identity = null;
    _identityPublic = null;
    await _storage.delete(key: _keyPairStoreKey);
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
