import 'dart:convert';
import 'dart:math' as math;

/// ---------------------------------------------------------------------------
/// Wire + storage models.
///
/// The server only ever sees `envelope` for a message; everything else on
/// [ChatMessage] that looks human (text, media name, catalog snapshot) is
/// decrypted locally and cached in the encrypted Hive box.
/// ---------------------------------------------------------------------------

enum MessageKind { text, media, catalog, system }

enum MessageStatus { sending, sent, delivered, read, failed }

MessageKind _kindFromWire(String? value) => switch (value) {
      'media' => MessageKind.media,
      'catalog' => MessageKind.catalog,
      'system' => MessageKind.system,
      _ => MessageKind.text,
    };

String kindToWire(MessageKind kind) => switch (kind) {
      MessageKind.text => 'text',
      MessageKind.media => 'media',
      MessageKind.catalog => 'catalog',
      MessageKind.system => 'system',
    };

/// Local-only view of a peer or of the signed-in user.
class ChatUser {
  const ChatUser({
    required this.id,
    required this.displayName,
    this.username = '',
    this.phone,
    this.countryCode,
    this.isBusiness = false,
    this.businessName,
    this.accentColor = '#4F46E5',
    this.identityKey,
    this.lastSeenAt,
  });

  final String id;
  final String displayName;
  final String username;
  final String? phone;
  final String? countryCode;
  final bool isBusiness;
  final String? businessName;
  final String accentColor;
  final String? identityKey;
  final DateTime? lastSeenAt;

  bool get hasKey => identityKey != null && identityKey!.isNotEmpty;

  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters(2);
    return '${parts.first.characters(1)}${parts.last.characters(1)}';
  }

  factory ChatUser.fromJson(Map<String, dynamic> json) => ChatUser(
        id: json['id'] as String,
        displayName: (json['displayName'] ?? json['display_name'] ?? 'Friend') as String,
        username: (json['username'] ?? '') as String,
        phone: json['phone'] as String?,
        countryCode: json['countryCode'] as String?,
        isBusiness: json['isBusiness'] == true,
        businessName: json['businessName'] as String?,
        accentColor: (json['accentColor'] ?? '#4F46E5') as String,
        identityKey: json['identityKey'] as String?,
        lastSeenAt: json['lastSeenAt'] != null ? DateTime.tryParse(json['lastSeenAt'] as String) : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'username': username,
        'phone': phone,
        'countryCode': countryCode,
        'isBusiness': isBusiness,
        'businessName': businessName,
        'accentColor': accentColor,
        'identityKey': identityKey,
        'lastSeenAt': lastSeenAt?.toIso8601String(),
      };

  ChatUser copyWith({String? displayName, String? identityKey, bool? isBusiness, String? businessName}) =>
      ChatUser(
        id: id,
        displayName: displayName ?? this.displayName,
        username: username,
        phone: phone,
        countryCode: countryCode,
        isBusiness: isBusiness ?? this.isBusiness,
        businessName: businessName ?? this.businessName,
        accentColor: accentColor,
        identityKey: identityKey ?? this.identityKey,
        lastSeenAt: lastSeenAt,
      );
}

extension _Chars on String {
  String characters(int n) => length <= n ? this : substring(0, n).toUpperCase();
}

/// Attachment descriptor. The bytes live encrypted on the server; this object
/// is what travels *inside* the encrypted envelope.
class MediaAttachment {
  const MediaAttachment({
    required this.id,
    required this.mimeType,
    required this.sizeBytes,
    this.fileName,
    this.width,
    this.height,
    this.durationMs,
    this.blurHash,
    this.keyBase64,
  });

  final String id;
  final String mimeType;
  final int sizeBytes;
  final String? fileName;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? blurHash;

  /// AES key for the encrypted blob. Travels only inside the E2EE envelope.
  final String? keyBase64;

  bool get isImage => mimeType.startsWith('image/');
  bool get isVideo => mimeType.startsWith('video/');
  bool get isAudio => mimeType.startsWith('audio/');

  Map<String, dynamic> toJson() => {
        'id': id,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'fileName': fileName,
        'width': width,
        'height': height,
        'durationMs': durationMs,
        'blurHash': blurHash,
        'keyBase64': keyBase64,
      };

  factory MediaAttachment.fromJson(Map<String, dynamic> json) => MediaAttachment(
        id: json['id'] as String,
        mimeType: (json['mimeType'] ?? 'application/octet-stream') as String,
        sizeBytes: (json['sizeBytes'] ?? 0) as int,
        fileName: json['fileName'] as String?,
        width: json['width'] as int?,
        height: json['height'] as int?,
        durationMs: json['durationMs'] as int?,
        blurHash: json['blurHash'] as String?,
        keyBase64: json['keyBase64'] as String?,
      );
}

/// A decrypted catalog item snapshot attached to a shared product message.
class CatalogSnapshot {
  const CatalogSnapshot({
    required this.itemId,
    required this.name,
    required this.priceLabel,
    this.description,
    this.imageMediaId,
  });

  final String itemId;
  final String name;
  final String priceLabel;
  final String? description;
  final String? imageMediaId;

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'name': name,
        'priceLabel': priceLabel,
        'description': description,
        'imageMediaId': imageMediaId,
      };

  factory CatalogSnapshot.fromJson(Map<String, dynamic> json) => CatalogSnapshot(
        itemId: json['itemId'] as String,
        name: json['name'] as String,
        priceLabel: (json['priceLabel'] ?? '') as String,
        description: json['description'] as String?,
        imageMediaId: json['imageMediaId'] as String?,
      );
}

class ChatMessage {
  const ChatMessage({
    required this.uuid,
    required this.clientId,
    required this.conversationId,
    required this.senderId,
    required this.createdAt,
    required this.kind,
    this.seq = 0,
    this.envelope,
    this.text,
    this.status = MessageStatus.sending,
    this.mediaId,
    this.media,
    this.catalog,
    this.replyTo,
    this.deliveredAt,
    this.readAt,
    this.deleted = false,
    this.outgoing = false,
    this.failedReason,
  });

  /// Server-visible identity.
  final String uuid;
  final String clientId;
  final String conversationId;
  final String senderId;
  final int seq;
  final MessageKind kind;
  final String? envelope;
  final String? mediaId;
  final String? replyTo;

  /// Local-only, decrypted once and cached.
  final String? text;
  final MediaAttachment? media;
  final CatalogSnapshot? catalog;

  final DateTime createdAt;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final MessageStatus status;
  final bool deleted;
  final bool outgoing;
  final String? failedReason;

  bool get isMedia => kind == MessageKind.media;
  bool get isCatalog => kind == MessageKind.catalog;

  /// Three ticks states required by the brief: sent, delivered, read.
  MessageStatus get effectiveStatus {
    if (deleted) return status;
    if (readAt != null) return MessageStatus.read;
    if (deliveredAt != null) return MessageStatus.delivered;
    return status;
  }

  ChatMessage copyWith({
    int? seq,
    String? envelope,
    String? text,
    MessageStatus? status,
    MediaAttachment? media,
    CatalogSnapshot? catalog,
    DateTime? deliveredAt,
    DateTime? readAt,
    bool? deleted,
    String? failedReason,
  }) =>
      ChatMessage(
        uuid: uuid,
        clientId: clientId,
        conversationId: conversationId,
        senderId: senderId,
        createdAt: createdAt,
        kind: kind,
        seq: seq ?? this.seq,
        envelope: envelope ?? this.envelope,
        text: text ?? this.text,
        status: status ?? this.status,
        mediaId: mediaId,
        media: media ?? this.media,
        catalog: catalog ?? this.catalog,
        replyTo: replyTo,
        deliveredAt: deliveredAt ?? this.deliveredAt,
        readAt: readAt ?? this.readAt,
        deleted: deleted ?? this.deleted,
        outgoing: outgoing,
        failedReason: failedReason ?? this.failedReason,
      );

  factory ChatMessage.fromWire(Map<String, dynamic> json, {required String myUserId}) {
    final readAt = json['readAt'] as String?;
    final deliveredAt = json['deliveredAt'] as String?;
    final status = readAt != null
        ? MessageStatus.read
        : deliveredAt != null
            ? MessageStatus.delivered
            : MessageStatus.sent;

    return ChatMessage(
      uuid: json['uuid'] as String,
      clientId: (json['clientId'] ?? '') as String,
      conversationId: json['conversationId'] as String,
      senderId: json['senderId'] as String,
      seq: (json['seq'] ?? 0) as int,
      kind: _kindFromWire(json['kind'] as String?),
      envelope: json['envelope'] as String?,
      mediaId: json['mediaId'] as String?,
      replyTo: json['replyTo'] as String?,
      createdAt: DateTime.tryParse((json['createdAt'] ?? '') as String) ?? DateTime.now(),
      deliveredAt: deliveredAt != null ? DateTime.tryParse(deliveredAt) : null,
      readAt: readAt != null ? DateTime.tryParse(readAt) : null,
      deleted: json['deletedAt'] != null,
      status: status,
      outgoing: json['senderId'] == myUserId,
    );
  }

  Map<String, dynamic> toMap() => {
        'uuid': uuid,
        'clientId': clientId,
        'conversationId': conversationId,
        'senderId': senderId,
        'seq': seq,
        'kind': kind.name,
        'envelope': envelope,
        'text': text,
        'mediaId': mediaId,
        'media': media?.toJson(),
        'catalog': catalog?.toJson(),
        'replyTo': replyTo,
        'createdAt': createdAt.toIso8601String(),
        'deliveredAt': deliveredAt?.toIso8601String(),
        'readAt': readAt?.toIso8601String(),
        'status': status.name,
        'deleted': deleted,
        'outgoing': outgoing,
      };

  factory ChatMessage.fromMap(Map<dynamic, dynamic> map) {
    final media = map['media'];
    final catalog = map['catalog'];
    return ChatMessage(
      uuid: map['uuid'] as String,
      clientId: (map['clientId'] ?? '') as String,
      conversationId: map['conversationId'] as String,
      senderId: (map['senderId'] ?? '') as String,
      seq: (map['seq'] ?? 0) as int,
      kind: MessageKind.values.firstWhere(
        (k) => k.name == map['kind'],
        orElse: () => MessageKind.text,
      ),
      envelope: map['envelope'] as String?,
      text: map['text'] as String?,
      mediaId: map['mediaId'] as String?,
      media: media is Map ? MediaAttachment.fromJson(Map<String, dynamic>.from(media)) : null,
      catalog: catalog is Map ? CatalogSnapshot.fromJson(Map<String, dynamic>.from(catalog)) : null,
      replyTo: map['replyTo'] as String?,
      createdAt: DateTime.tryParse((map['createdAt'] ?? '') as String) ?? DateTime.now(),
      deliveredAt: map['deliveredAt'] != null ? DateTime.tryParse(map['deliveredAt'] as String) : null,
      readAt: map['readAt'] != null ? DateTime.tryParse(map['readAt'] as String) : null,
      status: MessageStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => MessageStatus.sent,
      ),
      deleted: map['deleted'] == true,
      outgoing: map['outgoing'] == true,
    );
  }
}

/// The plaintext payload that goes *inside* the encrypted envelope.
class EnvelopeBody {
  const EnvelopeBody({
    this.text,
    this.media,
    this.catalog,
    this.action,
    this.replyPreview,
  });

  final String? text;
  final MediaAttachment? media;
  final CatalogSnapshot? catalog;

  /// Used by the auto-responder so the peer can render "automatic reply".
  final String? action;
  final String? replyPreview;

  Map<String, dynamic> toJson() => {
        if (text != null) 'text': text,
        if (media != null) 'media': media!.toJson(),
        if (catalog != null) 'catalog': catalog!.toJson(),
        if (action != null) 'action': action,
        if (replyPreview != null) 'replyPreview': replyPreview,
      };

  String encode() => jsonEncode(toJson());

  factory EnvelopeBody.decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return EnvelopeBody(
      text: json['text'] as String?,
      media: json['media'] != null ? MediaAttachment.fromJson(json['media'] as Map<String, dynamic>) : null,
      catalog: json['catalog'] != null
          ? CatalogSnapshot.fromJson(json['catalog'] as Map<String, dynamic>)
          : null,
      action: json['action'] as String?,
      replyPreview: json['replyPreview'] as String?,
    );
  }
}

/* -------------------------------------------------------------------------- */
/* Business tooling                                                           */
/* -------------------------------------------------------------------------- */

class QuickReply {
  const QuickReply({
    required this.id,
    required this.shortcut,
    required this.body,
    this.title = '',
  });

  final String id;
  final String shortcut; // "/address"
  final String title;
  final String body;

  Map<String, dynamic> toJson() => {'id': id, 'shortcut': shortcut, 'title': title, 'body': body};

  factory QuickReply.fromJson(Map<String, dynamic> json) => QuickReply(
        id: json['id'] as String,
        shortcut: (json['shortcut'] ?? '') as String,
        title: (json['title'] ?? json['shortcut'] ?? '') as String,
        body: (json['body'] ?? '') as String,
      );

  QuickReply copyWith({String? shortcut, String? title, String? body}) =>
      QuickReply(id: id, shortcut: shortcut ?? this.shortcut, title: title ?? this.title, body: body ?? this.body);
}

class LabelTag {
  const LabelTag({required this.id, required this.name, required this.colorHex});

  final String id;
  final String name;
  final String colorHex;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': colorHex};

  factory LabelTag.fromJson(Map<String, dynamic> json) => LabelTag(
        id: json['id'] as String,
        name: (json['name'] ?? '') as String,
        colorHex: (json['color'] ?? '#6366F1') as String,
      );
}

class CatalogItem {
  const CatalogItem({
    required this.id,
    required this.name,
    required this.priceCents,
    this.currency = 'EUR',
    this.description,
    this.imageMediaId,
    this.active = true,
  });

  final String id;
  final String name;
  final int priceCents;
  final String currency;
  final String? description;
  final String? imageMediaId;
  final bool active;

  String get priceLabel {
    final symbol = switch (currency) {
      'EUR' => '€',
      'USD' => '\$',
      'GBP' => '£',
      'IDR' => 'Rp',
      'INR' => '₹',
      _ => '$currency ',
    };
    final amount = (priceCents / 100).toStringAsFixed(priceCents % 100 == 0 ? 0 : 2);
    return '$symbol$amount';
  }

  CatalogSnapshot toSnapshot() => CatalogSnapshot(
        itemId: id,
        name: name,
        priceLabel: priceLabel,
        description: description,
        imageMediaId: imageMediaId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'priceCents': priceCents,
        'currency': currency,
        'description': description,
        'imageMediaId': imageMediaId,
        'active': active,
      };

  factory CatalogItem.fromJson(Map<String, dynamic> json) => CatalogItem(
        id: json['id'] as String,
        name: (json['name'] ?? '') as String,
        priceCents: (json['priceCents'] ?? 0) as int,
        currency: (json['currency'] ?? 'EUR') as String,
        description: json['description'] as String?,
        imageMediaId: json['imageMediaId'] as String?,
        active: json['active'] != false,
      );
}

/// Away schedule: "outside these hours" or "always".
class AwaySchedule {
  const AwaySchedule({this.startHour = 22, this.endHour = 7});

  final int startHour;
  final int endHour;

  /// True when [now] falls inside the away window (handles overnight ranges).
  bool isActiveAt(DateTime now) {
    final hour = now.hour;
    if (startHour == endHour) return false;
    if (startHour < endHour) return hour >= startHour && hour < endHour;
    return hour >= startHour || hour < endHour;
  }

  Map<String, dynamic> toJson() => {'startHour': startHour, 'endHour': endHour};

  factory AwaySchedule.fromJson(Map<String, dynamic> json) => AwaySchedule(
        startHour: (json['startHour'] ?? 22) as int,
        endHour: (json['endHour'] ?? 7) as int,
      );

  String get label => '${_hh(startHour)} – ${_hh(endHour)}';
  static String _hh(int h) => '${h.toString().padLeft(2, '0')}:00';
}

class AutoReplySettings {
  const AutoReplySettings({
    this.greetingEnabled = false,
    this.greetingText = "Hi! Thanks for messaging. I'll reply as soon as I can.",
    this.awayEnabled = false,
    this.awayText = "I'm away right now and will get back to you in the morning.",
    this.awaySchedule = const AwaySchedule(),
    this.cooldownHours = 8,
  });

  final bool greetingEnabled;
  final String greetingText;
  final bool awayEnabled;
  final String awayText;
  final AwaySchedule awaySchedule;

  /// Avoids spamming the same person every message.
  final int cooldownHours;

  AutoReplySettings copyWith({
    bool? greetingEnabled,
    String? greetingText,
    bool? awayEnabled,
    String? awayText,
    AwaySchedule? awaySchedule,
    int? cooldownHours,
  }) =>
      AutoReplySettings(
        greetingEnabled: greetingEnabled ?? this.greetingEnabled,
        greetingText: greetingText ?? this.greetingText,
        awayEnabled: awayEnabled ?? this.awayEnabled,
        awayText: awayText ?? this.awayText,
        awaySchedule: awaySchedule ?? this.awaySchedule,
        cooldownHours: cooldownHours ?? this.cooldownHours,
      );

  Map<String, dynamic> toJson() => {
        'greeting': {'enabled': greetingEnabled, 'text': greetingText},
        'away': {
          'enabled': awayEnabled,
          'text': awayText,
          'schedule': awaySchedule.toJson(),
        },
        'cooldownHours': cooldownHours,
      };

  factory AutoReplySettings.fromJson(Map<String, dynamic> json) {
    // Tolerate a missing section, and a section that is not a map at all:
    // settings are re-read on every launch, so a bad cache must not crash.
    final greeting = json['greeting'] is Map
        ? Map<String, dynamic>.from(json['greeting'] as Map)
        : const <String, dynamic>{};
    final away = json['away'] is Map
        ? Map<String, dynamic>.from(json['away'] as Map)
        : const <String, dynamic>{};
    return AutoReplySettings(
      greetingEnabled: greeting['enabled'] == true,
      greetingText: (greeting['text'] ?? '') as String,
      awayEnabled: away['enabled'] == true,
      awayText: (away['text'] ?? '') as String,
      awaySchedule: away['schedule'] is Map
          ? AwaySchedule.fromJson(Map<String, dynamic>.from(away['schedule'] as Map))
          : const AwaySchedule(),
      cooldownHours: (json['cooldownHours'] ?? 8) as int,
    );
  }
}

/// A candidate address for the server, used by the connection race.
class ServerEndpoint {
  const ServerEndpoint({required this.url, required this.kind, this.label});

  final String url;
  final EndpointKind kind;
  final String? label;

  bool get isSecure => url.startsWith('wss://') || url.startsWith('https://');
  bool get isLocal => kind == EndpointKind.lan || kind == EndpointKind.loopback;

  String get httpBase => url
      .replaceFirst('ws://', 'http://')
      .replaceFirst('wss://', 'https://')
      .replaceAll(RegExp(r'/+$'), '');

  String get socketBase => httpBase.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');

  @override
  String toString() => '$kind:$url';
}

enum EndpointKind { loopback, lan, tailnet, public }

enum ConnectionStatus { offline, probing, connecting, online, degraded }

/// Trimmed-down view of a connection for the UI.
class ConnectionInfo {
  const ConnectionInfo({
    required this.status,
    this.endpoint,
    this.rttMs,
    this.peerOnline = false,
    this.lastError,
  });

  final ConnectionStatus status;
  final ServerEndpoint? endpoint;
  final int? rttMs;
  final bool peerOnline;
  final String? lastError;

  bool get isOnline => status == ConnectionStatus.online || status == ConnectionStatus.degraded;

  String get label => switch (status) {
        ConnectionStatus.online => endpoint?.kind == EndpointKind.lan ? 'On your Wi-Fi' : 'Connected',
        ConnectionStatus.degraded => 'Weak connection',
        ConnectionStatus.connecting => 'Connecting…',
        ConnectionStatus.probing => 'Finding server…',
        ConnectionStatus.offline => 'Offline — showing cached messages',
      };
}

/// Convenience for the avatar colours stored as "#RRGGBB".
int parseHexColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  return int.tryParse(cleaned, radix: 16) ?? 0x4F46E5;
}

/// Rough "?" -> minutes helper used by the chat list subtitle.
String formatRelative(DateTime time, {DateTime? now}) {
  final base = now ?? DateTime.now();
  final diff = base.difference(time);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays == 1) return 'yesterday';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return '${time.day}/${time.month}';
}

String formatClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// Human file size, used on attachment bubbles.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

double clampDouble(double value, double min, double max) => math.min(math.max(value, min), max);
