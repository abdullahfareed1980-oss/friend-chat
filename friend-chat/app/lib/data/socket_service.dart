import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/models.dart';

/// A decoded server event.
class SocketEvent {
  const SocketEvent(this.name, this.data);
  final String name;
  final Map<String, dynamic> data;
}

class SendResult {
  const SendResult({required this.ok, this.message, this.duplicate = false, this.error});
  final bool ok;
  final ChatMessage? message;
  final bool duplicate;
  final String? error;
}

/// ---------------------------------------------------------------------------
/// Secure WebSocket transport (Socket.io over `wss://`).
///
/// Everything the UI needs arrives as a [SocketEvent]. Sending is a future that
/// completes with the server's ack, which is what lets the bubble go from a
/// clock icon to a single tick only when the server has actually persisted it.
/// ---------------------------------------------------------------------------

class SocketService {
  SocketService({this.requestTimeout = const Duration(seconds: 12)});

  final Duration requestTimeout;

  io.Socket? _socket;
  final StreamController<SocketEvent> _events = StreamController.broadcast();
  final StreamController<ConnectionStatus> _status = StreamController.broadcast();

  ServerEndpoint? _endpoint;
  bool _intentionalClose = false;

  Stream<SocketEvent> get events => _events.stream;
  Stream<ConnectionStatus> get status => _status.stream;
  bool get isConnected => _socket?.connected ?? false;
  ServerEndpoint? get endpoint => _endpoint;

  /// Connects (or reconnects) to [endpoint]. Never call twice with the same
  /// endpoint without disposing first - the app-level controller handles that.
  Future<bool> connect({required ServerEndpoint endpoint, required String token}) async {
    _endpoint = endpoint;
    _intentionalClose = false;
    _status.add(ConnectionStatus.connecting);

    await _teardown();

    final socket = io.io(
      endpoint.socketBase,
      io.OptionBuilder()
          .setTransports(['websocket']) // no long-polling: survives handoffs
          .setAuth({'token': token, 'device': _deviceDescriptor})
          .enableReconnection()
          .setReconnectionAttempts(1000)
          .setReconnectionDelay(800)
          .setReconnectionDelayMax(15000)
          .setTimeout(12000)
          .build(),
    );
    _socket = socket;

    final ready = Completer<bool>();

    socket.onConnect((_) {
      _status.add(ConnectionStatus.online);
      if (!ready.isCompleted) ready.complete(true);
    });

    socket.onDisconnect((reason) {
      _status.add(ConnectionStatus.offline);
      if (!ready.isCompleted) ready.complete(false);
      if (!_intentionalClose) {
        _events.add(SocketEvent('transport:offline', {'reason': '$reason'}));
      }
    });

    socket.onConnectError((error) {
      _status.add(ConnectionStatus.offline);
      if (!ready.isCompleted) ready.complete(false);
      _events.add(SocketEvent('transport:error', {'error': '$error'}));
    });

    socket.on('server:hello', (data) => _forward('server:hello', data));
    socket.on('message:new', (data) => _forward('message:new', data));
    socket.on('message:deleted', (data) => _forward('message:deleted', data));
    socket.on('receipt:update', (data) => _forward('receipt:update', data));
    socket.on('typing', (data) => _forward('typing', data));
    socket.on('presence', (data) => _forward('presence', data));
    socket.on('peer:identity', (data) => _forward('peer:identity', data));
    socket.on('business:update', (data) => _forward('business:update', data));

    return ready.future.timeout(const Duration(seconds: 15), onTimeout: () => false);
  }

  Map<String, String>? _deviceDescriptor;

  /// Identifies this install to the server for multi-device fan-out.
  void setDevice({required String id, required String name, required String platform}) {
    _deviceDescriptor = {'id': id, 'name': name, 'platform': platform};
  }

  void _forward(String name, dynamic data) {
    if (_events.isClosed) return;
    final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    _events.add(SocketEvent(name, map));
  }

  /// Fire-and-forget with ack.
  Future<Map<String, dynamic>> _emit(String event, Map<String, dynamic> payload) {
    final socket = _socket;
    final completer = Completer<Map<String, dynamic>>();
    if (socket == null || !socket.connected) {
      completer.complete({'ok': false, 'error': 'offline'});
      return completer.future;
    }

    socket.emitWithAck(
      event,
      payload,
      ack: (dynamic data) {
        final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{'ok': true};
        if (!completer.isCompleted) completer.complete(map);
      },
    );

    return completer.future.timeout(
      requestTimeout,
      onTimeout: () => {'ok': false, 'error': 'timeout'},
    );
  }

  Future<SendResult> sendMessage({
    required String conversationId,
    required String clientId,
    required String kind,
    required String envelope,
    String? mediaId,
    String? replyTo,
    required String myUserId,
  }) async {
    final ack = await _emit('message:send', {
      'conversationId': conversationId,
      'clientId': clientId,
      'kind': kind,
      'envelope': envelope,
      if (mediaId != null) 'mediaId': mediaId,
      if (replyTo != null) 'replyTo': replyTo,
    });

    final raw = ack['message'];
    return SendResult(
      ok: ack['ok'] == true,
      duplicate: ack['duplicate'] == true,
      message: raw is Map ? ChatMessage.fromWire(Map<String, dynamic>.from(raw), myUserId: myUserId) : null,
      error: ack['error'] as String?,
    );
  }

  Future<void> markDelivered(List<int> seqs) async {
    if (seqs.isEmpty) return;
    await _emit('receipt:delivered', {'seqs': seqs});
  }

  Future<void> markRead({required String conversationId, required int upToSeq}) async {
    if (upToSeq <= 0) return;
    await _emit('receipt:read', {'conversationId': conversationId, 'upToSeq': upToSeq});
  }

  Future<void> sendTyping({required String conversationId, required bool isTyping}) async {
    // Typing is best-effort and intentionally does not await an ack.
    _socket?.emit('typing', {'conversationId': conversationId, 'isTyping': isTyping});
  }

  Future<void> ping() async => _emit('presence:ping', {});

  Future<void> deleteMessage(String uuid) async => _emit('message:delete', {'uuid': uuid});

  Future<List<ChatMessage>> requestSync({required int sinceSeq, required String myUserId}) async {
    final ack = await _emit('sync:request', {'sinceSeq': sinceSeq, 'limit': 300});
    final list = ack['messages'];
    if (list is! List) return const [];
    return list
        .map((m) => ChatMessage.fromWire(Map<String, dynamic>.from(m as Map), myUserId: myUserId))
        .toList();
  }

  Future<void> _teardown() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      socket.off('server:hello');
      socket.off('message:new');
      socket.off('message:deleted');
      socket.off('receipt:update');
      socket.off('typing');
      socket.off('presence');
      socket.off('peer:identity');
      socket.off('business:update');
      socket.dispose();
    }
  }

  Future<void> disconnect() async {
    _intentionalClose = true;
    await _teardown();
    _status.add(ConnectionStatus.offline);
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
    await _status.close();
  }
}
