import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashing;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/socket_service.dart';
import '../models/models.dart';
import '../services/auto_responder.dart';
import 'app_session.dart';

/// ---------------------------------------------------------------------------
/// The chat engine.
///
/// Responsibilities:
///   • optimistic send (bubble appears instantly, ticks move when the server
///     acks and again when the peer's device reports delivered/read)
///   • decrypt on arrival and never store a plaintext body on the server
///   • merge catch-up after a network switch using the `seq` cursor
///   • feed the offline cache so history is readable with no signal at all
/// ---------------------------------------------------------------------------

class ChatController extends ChangeNotifier {
  ChatController({required this.session, AutoResponder? autoResponder})
      : _autoResponder = autoResponder ?? AutoResponder();

  final AppSession session;
  final AutoResponder _autoResponder;

  final List<ChatMessage> _messages = [];
  StreamSubscription<SocketEvent>? _eventsSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  Timer? _typingDebounce;

  bool peerTyping = false;
  bool peerOnline = false;
  int unreadCount = 0;
  bool syncing = false;
  String? lastSyncError;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  ChatMessage? get lastMessage => _messages.isEmpty ? null : _messages.last;

  String? get conversationId => session.conversationId;

  /* ------------------------------------------------------------------ */
  /* Lifecycle                                                           */
  /* ------------------------------------------------------------------ */

  Future<void> initialize() async {
    final conversation = session.conversationId;
    if (conversation == null) return;

    _messages
      ..clear()
      ..addAll(session.store.messagesFor(conversation));
    await _autoResponder.load(session.store);

    final lastRead = session.store.readMeta<int>('lastReadSeq') ?? 0;
    unreadCount = _messages.where((m) => !m.outgoing && m.seq > lastRead).length;

    _eventsSub ??= session.socket.events.listen(_onSocketEvent);
    _statusSub ??= session.socket.status.listen((status) {
      if (status == ConnectionStatus.online) unawaited(syncNow());
    });

    notifyListeners();
    await syncNow();
  }

  /// Pulls everything newer than the local cursor. Runs on cold start, on
  /// reconnect, and after a Wi-Fi <-> mobile-data handoff.
  Future<void> syncNow() async {
    final api = session.api;
    final conversation = session.conversationId;
    final me = session.user;
    if (api == null || conversation == null || me == null || syncing) return;

    syncing = true;
    notifyListeners();
    try {
      var cursor = session.store.cursor;
      for (var page = 0; page < 25; page++) {
        final result = await api.sync(sinceSeq: cursor, myUserId: me.id);
        if (result.messages.isEmpty) {
          cursor = result.latestSeq > cursor ? result.latestSeq : cursor;
          break;
        }
        for (final message in result.messages) {
          await _ingest(message);
        }
        cursor = result.latestSeq;
        await session.store.setCursor(cursor);
        if (!result.hasMore) break;
      }

      _sort();
      _recountUnread();
      lastSyncError = null;
      await _flushDelivered();
    } catch (err) {
      lastSyncError = '$err';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  void _onSocketEvent(SocketEvent event) {
    switch (event.name) {
      case 'message:new':
        unawaited(_handleIncoming(event.data));
      case 'receipt:update':
        unawaited(_handleReceipt(event.data));
      case 'typing':
        _handleTyping(event.data);
      case 'presence':
        final userId = event.data['userId'];
        if (userId != null && userId == session.user?.id) return;
        peerOnline = event.data['online'] == true;
        notifyListeners();
      case 'message:deleted':
        unawaited(_handleRemoteDelete(event.data));
      case 'peer:identity':
        final key = event.data['identityKey'] as String?;
        final userId = event.data['userId'] as String?;
        if (key != null && userId != null && userId == session.peer?.id) {
          session.peer = session.peer?.copyWith(identityKey: key);
          notifyListeners();
        }
      case 'server:hello':
        peerOnline = event.data['peerOnline'] == true;
        notifyListeners();
    }
  }

  /* ------------------------------------------------------------------ */
  /* Receiving                                                           */
  /* ------------------------------------------------------------------ */

  Future<void> _handleIncoming(Map<String, dynamic> data) async {
    final me = session.user;
    if (me == null) return;
    final wire = ChatMessage.fromWire(data, myUserId: me.id);
    final alreadyKnown = session.store.messageByUuid(wire.uuid);
    final merged = await _ingest(wire);
    if (merged == null) return;

    _sort();
    if (!merged.outgoing && alreadyKnown == null && merged.seq > 0) {
      await session.socket.markDelivered([merged.seq]);
      unreadCount += 1;

      final reply = await _autoResponder.decide(
        now: DateTime.now(),
        conversationRestarted: _isNewWindow(merged),
        store: session.store,
      );
      if (reply != null && reply.trim().isNotEmpty) {
        await _send(
          body: EnvelopeBody(text: reply, action: 'auto_reply').encode(),
          kind: MessageKind.text,
          localText: reply,
        );
      }
    }
    notifyListeners();
  }

  bool _isNewWindow(ChatMessage incoming) {
    final previous = session.store
        .messagesFor(incoming.conversationId)
        .where((m) => !m.outgoing && m.uuid != incoming.uuid)
        .toList();
    if (previous.isEmpty) return true;
    final gap = incoming.createdAt.difference(previous.last.createdAt).inHours;
    return gap >= 12;
  }

  /// Decrypts (when possible) and persists one message from the server.
  Future<ChatMessage?> _ingest(ChatMessage wire) async {
    final me = session.user;
    if (me == null) return null;

    final existing = session.store.messageByUuid(wire.uuid);
    if (existing != null) {
      final merged = existing.copyWith(
        seq: wire.seq,
        deliveredAt: wire.deliveredAt,
        readAt: wire.readAt,
        deleted: wire.deleted,
      );
      await session.store.put(merged);
      final index = _messages.indexWhere((m) => m.uuid == merged.uuid);
      if (index >= 0) _messages[index] = merged;
      return merged;
    }

    var text = wire.text;
    MediaAttachment? media = wire.media;
    CatalogSnapshot? catalog = wire.catalog;
    var status = wire.status;

    final envelope = wire.envelope;
    if (envelope != null && envelope.isNotEmpty) {
      try {
        final plain = await session.crypto.decryptFromPeer(
          envelopeBase64: envelope,
          myUserId: me.id,
          senderId: wire.senderId,
          conversationId: wire.conversationId,
        );
        final body = EnvelopeBody.decode(plain);
        text = body.text ?? body.replyPreview;
        media = body.media ?? media;
        catalog = body.catalog ?? catalog;
      } catch (_) {
        // Two possibilities: this is another of my own devices (each device
        // holds its own identity key), or the envelope is not addressed to us.
        text = wire.senderId == me.id
            ? 'Sent from another device'
            : 'Could not decrypt this message';
        status = wire.outgoing ? status : MessageStatus.sent;
      }
    }

    final resolved = ChatMessage(
      uuid: wire.uuid,
      clientId: wire.clientId,
      conversationId: wire.conversationId,
      senderId: wire.senderId,
      seq: wire.seq,
      kind: wire.kind,
      envelope: envelope,
      text: text,
      mediaId: wire.mediaId,
      media: media,
      catalog: catalog,
      replyTo: wire.replyTo,
      createdAt: wire.createdAt,
      deliveredAt: wire.deliveredAt,
      readAt: wire.readAt,
      deleted: wire.deleted,
      status: status,
      outgoing: wire.outgoing,
    );

    await session.store.put(resolved);
    final index = _messages.indexWhere((m) => m.uuid == resolved.uuid || m.clientId == resolved.clientId);
    if (index >= 0) {
      _messages[index] = resolved;
    } else {
      _messages.add(resolved);
    }
    if (resolved.seq > session.store.cursor) await session.store.setCursor(resolved.seq);
    return resolved;
  }

  Future<void> _handleReceipt(Map<String, dynamic> data) async {
    final upToSeq = (data['upToSeq'] as num?)?.toInt() ?? 0;
    final status = data['status'] as String?;
    final at = DateTime.tryParse((data['at'] ?? '') as String) ?? DateTime.now();
    if (upToSeq <= 0) return;

    var changed = false;
    for (var i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      if (!message.outgoing || message.seq == 0 || message.seq > upToSeq) continue;

      final updated = status == 'read'
          ? message.copyWith(readAt: at, deliveredAt: message.deliveredAt ?? at, status: MessageStatus.read)
          : message.copyWith(deliveredAt: at, status: MessageStatus.delivered);
      if (updated.readAt != message.readAt || updated.deliveredAt != message.deliveredAt) {
        _messages[i] = updated;
        await session.store.put(updated);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void _handleTyping(Map<String, dynamic> data) {
    final userId = data['userId'];
    if (userId == session.user?.id) return;
    peerTyping = data['isTyping'] == true;
    notifyListeners();
    // Safety net: clear a stale indicator if the "stop" packet is lost.
    _typingDebounce?.cancel();
    if (peerTyping) {
      _typingDebounce = Timer(const Duration(seconds: 6), () {
        peerTyping = false;
        notifyListeners();
      });
    }
  }

  Future<void> _handleRemoteDelete(Map<String, dynamic> data) async {
    final uuid = data['uuid'] as String?;
    if (uuid == null) return;
    final index = _messages.indexWhere((m) => m.uuid == uuid);
    if (index < 0) return;
    final tombstone = _messages[index].copyWith(deleted: true, text: null);
    _messages[index] = tombstone;
    await session.store.put(tombstone);
    notifyListeners();
  }

  /* ------------------------------------------------------------------ */
  /* Sending                                                             */
  /* ------------------------------------------------------------------ */

  Future<void> sendText(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return;
    await _send(body: EnvelopeBody(text: text).encode(), kind: MessageKind.text, localText: text);
  }

  Future<void> sendCatalogItem(CatalogItem item) async {
    await _send(
      body: EnvelopeBody(catalog: item.toSnapshot()).encode(),
      kind: MessageKind.catalog,
      localText: item.name,
      catalog: item.toSnapshot(),
    );
  }

  /// Picks a photo/file, encrypts it locally, uploads ciphertext, then sends a
  /// normal E2EE message that carries the decryption key and the metadata.
  Future<void> pickAndSendAttachment() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.media, withData: false);
    final file = picked?.files.single;
    final path = file?.path;
    if (file == null || path == null) return;

    final conversation = session.conversationId;
    final api = session.api;
    if (conversation == null || api == null) return;

    final clear = await File(path).readAsBytes();
    final encrypted = await session.crypto.encryptAttachment(clear);
    final digest = hashing.sha256.convert(encrypted.bytes).toString();
    final mediaId = await api.uploadMedia(
      cipherText: encrypted.bytes,
      conversationId: conversation,
      sha256Hex: digest,
    );

    final attachment = MediaAttachment(
      id: mediaId,
      mimeType: _mimeFor(file.name),
      sizeBytes: clear.length,
      fileName: file.name,
      keyBase64: encrypted.keyBase64,
    );

    await _send(
      body: EnvelopeBody(media: attachment).encode(),
      kind: MessageKind.media,
      media: attachment,
      mediaId: mediaId,
    );
  }

  Future<void> _send({
    required String body,
    required MessageKind kind,
    String? localText,
    MediaAttachment? media,
    CatalogSnapshot? catalog,
    String? mediaId,
  }) async {
    final me = session.user;
    final peer = session.peer;
    final conversation = session.conversationId;
    if (me == null || conversation == null) return;

    if (peer?.identityKey == null || peer!.identityKey!.isEmpty) {
      lastSyncError =
          'Waiting for ${peer?.displayName ?? 'your friend'} to open Friend Chat once to exchange keys.';
      notifyListeners();
      return;
    }

    final clientId = const Uuid().v4();
    final optimistic = ChatMessage(
      uuid: clientId,
      clientId: clientId,
      conversationId: conversation,
      senderId: me.id,
      kind: kind,
      text: localText,
      media: media,
      catalog: catalog,
      mediaId: mediaId,
      createdAt: DateTime.now(),
      status: MessageStatus.sending,
      outgoing: true,
    );

    _messages.add(optimistic);
    _sort();
    notifyListeners();
    await session.store.put(optimistic);

    try {
      final envelope = await session.crypto.encryptForPeer(
        plainText: body,
        myUserId: me.id,
        recipientId: peer.id,
        recipientPublicKeyBase64: peer.identityKey!,
        conversationId: conversation,
      );

      final result = await session.socket.sendMessage(
        conversationId: conversation,
        clientId: clientId,
        kind: kindToWire(kind),
        envelope: envelope,
        mediaId: mediaId,
        myUserId: me.id,
      );

      if (!result.ok || result.message == null) {
        throw Exception(result.error ?? 'send failed');
      }

      final confirmed = ChatMessage(
        uuid: result.message!.uuid,
        clientId: clientId,
        conversationId: conversation,
        senderId: me.id,
        seq: result.message!.seq,
        kind: kind,
        envelope: envelope,
        text: localText,
        media: media,
        catalog: catalog,
        mediaId: mediaId,
        createdAt: result.message!.createdAt,
        status: MessageStatus.sent,
        outgoing: true,
      );

      _messages.removeWhere((m) => m.clientId == clientId);
      await session.store.delete(clientId);
      _messages.add(confirmed);
      await session.store.put(confirmed);
      if (confirmed.seq > session.store.cursor) await session.store.setCursor(confirmed.seq);
      _sort();
    } catch (err) {
      final index = _messages.indexWhere((m) => m.clientId == clientId);
      if (index >= 0) {
        _messages[index] = _messages[index].copyWith(
          status: MessageStatus.failed,
          failedReason: '$err',
        );
        await session.store.put(_messages[index]);
      }
    }
    notifyListeners();
  }

  Future<void> retry(ChatMessage message) async {
    if (message.status != MessageStatus.failed || message.text == null) return;
    _messages.removeWhere((m) => m.uuid == message.uuid);
    await session.store.delete(message.uuid);
    notifyListeners();
    await sendText(message.text!);
  }

  Future<void> deleteForEveryone(ChatMessage message) async {
    if (!message.outgoing) return;
    await session.socket.deleteMessage(message.uuid);
    final index = _messages.indexWhere((m) => m.uuid == message.uuid);
    if (index < 0) return;
    final tombstone = _messages[index].copyWith(deleted: true, text: null);
    _messages[index] = tombstone;
    await session.store.put(tombstone);
    notifyListeners();
  }

  /* ------------------------------------------------------------------ */
  /* Read state + typing                                                 */
  /* ------------------------------------------------------------------ */

  Future<void> markConversationRead() async {
    final conversation = session.conversationId;
    if (conversation == null) return;
    final lastIncoming = _messages
        .where((m) => !m.outgoing && m.seq > 0)
        .fold<int>(0, (max, m) => m.seq > max ? m.seq : max);
    if (lastIncoming == 0) {
      unreadCount = 0;
      notifyListeners();
      return;
    }
    await session.store.writeMeta('lastReadSeq', lastIncoming);
    unreadCount = 0;
    notifyListeners();
    await session.socket.markRead(conversationId: conversation, upToSeq: lastIncoming);
  }

  Future<void> _flushDelivered() async {
    final pending = _messages
        .where((m) => !m.outgoing && m.seq > 0 && m.deliveredAt == null)
        .map((m) => m.seq)
        .toList();
    if (pending.isNotEmpty) await session.socket.markDelivered(pending);
  }

  void notifyTypingTimer() {
    final conversation = session.conversationId;
    if (conversation == null) return;
    unawaited(session.socket.sendTyping(conversationId: conversation, isTyping: true));
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(milliseconds: 1800), () {
      unawaited(session.socket.sendTyping(conversationId: conversation, isTyping: false));
    });
  }

  /* ------------------------------------------------------------------ */
  /* Helpers                                                             */
  /* ------------------------------------------------------------------ */

  void _sort() {
    _messages.sort((a, b) {
      if (a.seq > 0 && b.seq > 0) return a.seq.compareTo(b.seq);
      if (a.seq > 0) return -1;
      if (b.seq > 0) return 1;
      return a.createdAt.compareTo(b.createdAt);
    });
  }

  void _recountUnread() {
    final lastRead = session.store.readMeta<int>('lastReadSeq') ?? 0;
    unreadCount = _messages.where((m) => !m.outgoing && m.seq > lastRead).length;
  }

  static String _mimeFor(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.ogg') || lower.endsWith('.opus')) return 'audio/ogg';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'application/octet-stream';
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    _eventsSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }
}
