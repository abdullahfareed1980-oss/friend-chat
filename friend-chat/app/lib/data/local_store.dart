import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/models.dart';

/// ---------------------------------------------------------------------------
/// Offline-first local store.
///
/// Two Hive boxes, both encrypted with an AES key that lives in the platform
/// keystore (flutter_secure_storage):
///   • `messages`  - decrypted text plus the envelope, keyed by uuid
///   • `meta`      - cursor, session, business documents, endpoint cache
///
/// A `seqIndex` box maps the server cursor to uuids so a reconnect can merge
/// without scanning everything. Chat history is readable with zero network,
/// which is the whole point of the cache.
/// ---------------------------------------------------------------------------

class LocalStore {
  LocalStore._();

  static const _messagesBox = 'fc_messages_v1';
  static const _metaBox = 'fc_meta_v1';
  static const _seqBox = 'fc_seq_v1';

  late Box<Map> _messages;
  late Box<Map> _meta;
  late Box<int> _seqIndex;

  static final LocalStore instance = LocalStore._();

  bool get isOpen => _messages.isOpen;

  Future<void> open(Uint8List encryptionKey) async {
    await Hive.initFlutter();
    final cipher = HiveAesCipher(encryptionKey);
    _messages = await Hive.openBox<Map>(_messagesBox, encryptionCipher: cipher);
    _meta = await Hive.openBox<Map>(_metaBox, encryptionCipher: cipher);
    _seqIndex = await Hive.openBox<int>(_seqBox, encryptionCipher: cipher);
  }

  Future<void> close() async {
    await Hive.close();
  }

  /* ------------------------------------------------------------------ */
  /* Messages                                                            */
  /* ------------------------------------------------------------------ */

  List<ChatMessage> messagesFor(String conversationId) {
    final list = _messages.values
        .map((raw) => ChatMessage.fromMap(raw))
        .where((m) => m.conversationId == conversationId)
        .toList()
      ..sort((a, b) {
        if (a.seq != 0 && b.seq != 0) return a.seq.compareTo(b.seq);
        return a.createdAt.compareTo(b.createdAt);
      });
    return list;
  }

  ChatMessage? messageByUuid(String uuid) {
    final raw = _messages.get(uuid);
    return raw == null ? null : ChatMessage.fromMap(raw);
  }

  ChatMessage? messageByClientId(String clientId) {
    for (final raw in _messages.values) {
      final message = ChatMessage.fromMap(raw);
      if (message.clientId == clientId) return message;
    }
    return null;
  }

  Future<void> put(ChatMessage message) async {
    await _messages.put(message.uuid, message.toMap());
    if (message.seq > 0) await _seqIndex.put(message.seq, 0);
  }

  Future<void> putAll(Iterable<ChatMessage> messages) async {
    final batch = <String, Map>{};
    for (final message in messages) {
      batch[message.uuid] = message.toMap();
    }
    await _messages.putAll(batch);
  }

  Future<void> delete(String uuid) async {
    final existing = messageByUuid(uuid);
    await _messages.delete(uuid);
    if (existing != null && existing.seq > 0) await _seqIndex.delete(existing.seq);
  }

  /// Highest server cursor we have durably stored.
  int get cursor {
    final stored = _meta.get('cursor');
    if (stored != null && stored['value'] is int) return stored['value'] as int;
    if (_seqIndex.isEmpty) return 0;
    return _seqIndex.keys.fold<int>(0, (max, key) => key > max ? key : max);
  }

  Future<void> setCursor(int value) => _meta.put('cursor', {'value': value});

  /* ------------------------------------------------------------------ */
  /* Generic meta (session, settings, endpoint cache)                     */
  /* ------------------------------------------------------------------ */

  T? readMeta<T>(String key) {
    final raw = _meta.get(key);
    if (raw == null) return null;
    final value = raw['value'];
    return value is T ? value : null;
  }

  Map<String, dynamic>? readMetaMap(String key) {
    final raw = _meta.get(key);
    if (raw == null) return null;
    final value = raw['value'];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<void> writeMeta(String key, Object? value) => _meta.put(key, {'value': value});

  Future<void> removeMeta(String key) => _meta.delete(key);

  List<Map<String, dynamic>> readMetaList(String key) {
    final raw = _meta.get(key);
    if (raw == null) return const [];
    final value = raw['value'];
    if (value is List) {
      return value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  Future<void> writeMetaList(String key, List<Map<String, dynamic>> items) =>
      _meta.put(key, {'value': items});

  Future<void> clearAll() async {
    await _messages.clear();
    await _meta.clear();
    await _seqIndex.clear();
  }

  /// Compact JSON export for the "export a backup" action in Settings.
  String exportJson() {
    final payload = {
      'exportedAt': DateTime.now().toIso8601String(),
      'cursor': cursor,
      'messages': messagesFor(readMeta<String>('conversationId') ?? '').map((m) => m.toMap()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }
}
