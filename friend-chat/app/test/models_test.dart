import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:friend_chat/models/models.dart';

/// models.dart is plain data: the app trusts it for the contents of every
/// bubble, so these tests pin two things — that a value survives a round trip
/// unchanged (cache, outbox, retry after restart) and that bad or missing wire
/// fields degrade to a sane default instead of throwing.
void main() {
  ChatUser user({String? identityKey, String displayName = 'Ann Lee'}) => ChatUser(
        id: 'u1',
        displayName: displayName,
        username: 'ann',
        phone: '+15550001',
        countryCode: 'US',
        identityKey: identityKey,
        lastSeenAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );

  ChatMessage message({
    MessageKind kind = MessageKind.text,
    DateTime? deliveredAt,
    DateTime? readAt,
    bool deleted = false,
    MessageStatus status = MessageStatus.sent,
  }) =>
      ChatMessage(
        uuid: 'm1',
        clientId: 'c1',
        conversationId: 'conv',
        senderId: 'u1',
        createdAt: DateTime.utc(2026, 2, 3, 4, 5, 6),
        kind: kind,
        envelope: 'enc',
        text: 'hello',
        status: status,
        mediaId: 'media-1',
        deliveredAt: deliveredAt,
        readAt: readAt,
        deleted: deleted,
      );

  group('ChatUser', () {
    test('survives a JSON round trip unchanged', () {
      final original = user(identityKey: 'PUBKEY');
      final restored = ChatUser.fromJson(original.toJson());

      expect(restored.id, 'u1');
      expect(restored.displayName, 'Ann Lee');
      expect(restored.username, 'ann');
      expect(restored.phone, '+15550001');
      expect(restored.countryCode, 'US');
      expect(restored.identityKey, 'PUBKEY');
      expect(restored.lastSeenAt, original.lastSeenAt);
      expect(restored.hasKey, isTrue);
    });

    test('falls back to snake_case display name, then to "Friend"', () {
      expect(ChatUser.fromJson({'id': 'a', 'display_name': 'Bob Ray'}).displayName, 'Bob Ray');
      expect(ChatUser.fromJson({'id': 'a'}).displayName, 'Friend');
    });

    test('prefers camelCase over snake_case and defaults the rest', () {
      final parsed = ChatUser.fromJson({'id': 'a', 'displayName': 'Cam', 'display_name': 'Snake'});

      expect(parsed.displayName, 'Cam');
      expect(parsed.username, '');
      expect(parsed.accentColor, '#4F46E5');
      expect(parsed.isBusiness, isFalse);
      expect(parsed.phone, isNull);
      expect(parsed.lastSeenAt, isNull);
      expect(parsed.hasKey, isFalse);
      expect(parsed.identityKey, isNull);
    });

    test('an empty identity key does not count as a key', () {
      expect(user(identityKey: '').hasKey, isFalse);
      expect(ChatUser.fromJson({'id': 'a', 'identityKey': ''}).hasKey, isFalse);
    });

    test('initials handles one word, two words, padding and blanks', () {
      expect(user(displayName: 'Zoe').initials, 'ZO');
      expect(user(displayName: 'Ann Lee').initials, 'AL');
      expect(user(displayName: 'ann marie lee').initials, 'AL');
      expect(user(displayName: '   spaced   out  ').initials, 'SO');
      expect(user(displayName: '   ').initials, '?');
      expect(user(displayName: '').initials, '?');
    });

    test('copyWith replaces only what it is given', () {
      final base = user(identityKey: 'OLD');
      final updated = base.copyWith(displayName: 'New Name', isBusiness: true, businessName: 'Shop');

      expect(updated.displayName, 'New Name');
      expect(updated.isBusiness, isTrue);
      expect(updated.businessName, 'Shop');
      expect(updated.identityKey, 'OLD', reason: 'a key must survive an unrelated edit');
      expect(updated.id, base.id);
      expect(updated.lastSeenAt, base.lastSeenAt);
    });

    test('copyWith with no arguments is an exact copy', () {
      final base = user(identityKey: 'KEY');
      final copy = base.copyWith();

      expect(copy.toJson(), base.toJson());
    });

    test('a malformed timestamp becomes null rather than throwing', () {
      expect(ChatUser.fromJson({'id': 'a', 'lastSeenAt': 'not-a-date'}).lastSeenAt, isNull);
    });
  });

  group('kindToWire', () {
    test('writes the string the server and the cache expect', () {
      expect(kindToWire(MessageKind.text), 'text');
      expect(kindToWire(MessageKind.media), 'media');
      expect(kindToWire(MessageKind.catalog), 'catalog');
      expect(kindToWire(MessageKind.system), 'system');
    });

    test('round trips through the wire format for every kind', () {
      // Guards against the two switches drifting apart.
      for (final kind in MessageKind.values) {
        final parsed = ChatMessage.fromWire(
          {
            'uuid': 'm',
            'conversationId': 'c',
            'senderId': 'peer',
            'kind': kindToWire(kind),
            'createdAt': '2026-01-01T00:00:00.000Z',
          },
          myUserId: 'me',
        );
        expect(parsed.kind, kind, reason: 'kindToWire($kind) must parse back to $kind');
      }
    });
  });

  group('MediaAttachment', () {
    test('survives a JSON round trip including the envelope key', () {
      const original = MediaAttachment(
        id: 'm1',
        mimeType: 'image/png',
        sizeBytes: 4096,
        fileName: 'a.png',
        width: 100,
        height: 200,
        durationMs: 1500,
        blurHash: 'LEHV6n',
        keyBase64: 'a2V5',
      );
      final restored = MediaAttachment.fromJson(jsonDecode(jsonEncode(original.toJson())));

      expect(restored.id, 'm1');
      expect(restored.mimeType, 'image/png');
      expect(restored.sizeBytes, 4096);
      expect(restored.fileName, 'a.png');
      expect(restored.width, 100);
      expect(restored.height, 200);
      expect(restored.durationMs, 1500);
      expect(restored.blurHash, 'LEHV6n');
      expect(restored.keyBase64, 'a2V5');
    });

    test('defaults mime type and size when the server omits them', () {
      final parsed = MediaAttachment.fromJson({'id': 'm2'});

      expect(parsed.mimeType, 'application/octet-stream');
      expect(parsed.sizeBytes, 0);
      expect(parsed.fileName, isNull);
      expect(parsed.keyBase64, isNull);
    });

    test('classifies by mime prefix, not by extension', () {
      MediaAttachment withType(String mime) =>
          MediaAttachment(id: 'x', mimeType: mime, sizeBytes: 1);

      expect(withType('image/jpeg').isImage, isTrue);
      expect(withType('video/mp4').isVideo, isTrue);
      expect(withType('audio/ogg').isAudio, isTrue);
      expect(withType('application/pdf').isImage, isFalse);
      expect(withType('application/pdf').isVideo, isFalse);
      expect(withType('application/pdf').isAudio, isFalse);
      expect(withType('IMAGE/PNG').isImage, isFalse, reason: 'mime types are case-sensitive');
    });
  });

  group('CatalogSnapshot', () {
    test('survives a JSON round trip', () {
      const original = CatalogSnapshot(
        itemId: 'i1',
        name: 'Coffee',
        priceLabel: '€2.50',
        description: 'Flat white',
        imageMediaId: 'media-9',
      );
      final restored = CatalogSnapshot.fromJson(original.toJson());

      expect(restored.itemId, 'i1');
      expect(restored.name, 'Coffee');
      expect(restored.priceLabel, '€2.50');
      expect(restored.description, 'Flat white');
      expect(restored.imageMediaId, 'media-9');
    });

    test('defaults a missing price label to empty', () {
      final parsed = CatalogSnapshot.fromJson({'itemId': 'i1', 'name': 'Tea'});

      expect(parsed.priceLabel, '');
      expect(parsed.description, isNull);
      expect(parsed.imageMediaId, isNull);
    });
  });

  group('ChatMessage.fromWire', () {
    Map<String, dynamic> wire([Map<String, dynamic> overrides = const {}]) => {
          'uuid': 'm1',
          'clientId': 'c1',
          'conversationId': 'conv',
          'senderId': 'peer',
          'seq': 7,
          'kind': 'media',
          'envelope': 'enc',
          'mediaId': 'media-1',
          'replyTo': 'm0',
          'createdAt': '2026-03-04T05:06:07.000Z',
          ...overrides,
        };

    test('parses the fields the server sends', () {
      final parsed = ChatMessage.fromWire(wire(), myUserId: 'me');

      expect(parsed.uuid, 'm1');
      expect(parsed.clientId, 'c1');
      expect(parsed.conversationId, 'conv');
      expect(parsed.senderId, 'peer');
      expect(parsed.seq, 7);
      expect(parsed.kind, MessageKind.media);
      expect(parsed.envelope, 'enc');
      expect(parsed.mediaId, 'media-1');
      expect(parsed.replyTo, 'm0');
      expect(parsed.createdAt, DateTime.utc(2026, 3, 4, 5, 6, 7));
      expect(parsed.outgoing, isFalse);
      expect(parsed.isMedia, isTrue);
      expect(parsed.isCatalog, isFalse);
    });

    test('marks the message outgoing only when I am the sender', () {
      expect(ChatMessage.fromWire(wire({'senderId': 'me'}), myUserId: 'me').outgoing, isTrue);
      expect(ChatMessage.fromWire(wire({'senderId': 'peer'}), myUserId: 'me').outgoing, isFalse);
    });

    test('maps every kind string, and anything unknown becomes text', () {
      MessageKind kindOf(String? value) =>
          ChatMessage.fromWire(wire({'kind': value}), myUserId: 'me').kind;

      expect(kindOf('text'), MessageKind.text);
      expect(kindOf('media'), MessageKind.media);
      expect(kindOf('catalog'), MessageKind.catalog);
      expect(kindOf('system'), MessageKind.system);
      expect(kindOf('bogus'), MessageKind.text);
      expect(kindOf(null), MessageKind.text);
    });

    test('derives delivery state from the timestamps', () {
      final unread = ChatMessage.fromWire(
        wire({'deliveredAt': '2026-03-04T05:07:00.000Z'}),
        myUserId: 'me',
      );
      expect(unread.status, MessageStatus.delivered);
      expect(unread.effectiveStatus, MessageStatus.delivered);

      final read = ChatMessage.fromWire(
        wire({'deliveredAt': '2026-03-04T05:07:00.000Z', 'readAt': '2026-03-04T05:09:00.000Z'}),
        myUserId: 'me',
      );
      expect(read.status, MessageStatus.read);
      expect(read.effectiveStatus, MessageStatus.read);

      final sent = ChatMessage.fromWire(wire(), myUserId: 'me');
      expect(sent.status, MessageStatus.sent);
      expect(sent.effectiveStatus, MessageStatus.sent);
    });

    test('a deletedAt timestamp marks the message deleted', () {
      expect(ChatMessage.fromWire(wire({'deletedAt': '2026-03-04T05:10:00.000Z'}), myUserId: 'me').deleted, isTrue);
      expect(ChatMessage.fromWire(wire(), myUserId: 'me').deleted, isFalse);
    });

    test('missing optional fields and a bad date do not throw', () {
      final parsed = ChatMessage.fromWire(
        {'uuid': 'm9', 'conversationId': 'c', 'senderId': 'peer', 'createdAt': 'yesterday'},
        myUserId: 'me',
      );

      expect(parsed.clientId, '');
      expect(parsed.seq, 0);
      expect(parsed.kind, MessageKind.text);
      expect(parsed.envelope, isNull);
      expect(parsed.mediaId, isNull);
      expect(parsed.replyTo, isNull);
      expect(parsed.deliveredAt, isNull);
      expect(parsed.readAt, isNull);
      // Falls back to "now" so the bubble still sorts sensibly.
      expect(parsed.createdAt.isAfter(DateTime.now().subtract(const Duration(minutes: 1))), isTrue);
    });
  });

  group('ChatMessage map cache', () {
    test('survives a toMap/fromMap round trip with nested media and catalog', () {
      final original = message(kind: MessageKind.catalog).copyWith(
        media: const MediaAttachment(
          id: 'm1',
          mimeType: 'image/jpeg',
          sizeBytes: 10,
          width: 4,
          height: 5,
          keyBase64: 'k',
        ),
        catalog: const CatalogSnapshot(itemId: 'i1', name: 'Coffee', priceLabel: '€2'),
        deliveredAt: DateTime.utc(2026, 2, 3, 4, 5, 7),
        readAt: DateTime.utc(2026, 2, 3, 4, 5, 8),
      );

      final restored = ChatMessage.fromMap(jsonDecode(jsonEncode(original.toMap())) as Map);

      expect(restored.uuid, original.uuid);
      expect(restored.clientId, original.clientId);
      expect(restored.conversationId, original.conversationId);
      expect(restored.senderId, original.senderId);
      expect(restored.kind, MessageKind.catalog);
      expect(restored.envelope, original.envelope);
      expect(restored.text, 'hello');
      expect(restored.mediaId, 'media-1');
      expect(restored.media?.mimeType, 'image/jpeg');
      expect(restored.media?.keyBase64, 'k');
      expect(restored.catalog?.name, 'Coffee');
      expect(restored.createdAt, original.createdAt);
      expect(restored.deliveredAt, original.deliveredAt);
      expect(restored.readAt, original.readAt);
      expect(restored.status, MessageStatus.sent);
      expect(restored.deleted, isFalse);
      expect(restored.outgoing, isFalse);
    });

    test('a media or catalog map that is not a map is ignored', () {
      final restored = ChatMessage.fromMap({
        'uuid': 'm1',
        'conversationId': 'conv',
        'senderId': 'u1',
        'kind': 'media',
        'createdAt': '2026-02-03T04:05:06.000Z',
        'media': 'garbage',
        'catalog': 42,
      });

      expect(restored.media, isNull);
      expect(restored.catalog, isNull);
      expect(restored.kind, MessageKind.media, reason: 'the kind survives even without payload');
    });

    test('unknown kind and status names fall back instead of throwing', () {
      final restored = ChatMessage.fromMap({
        'uuid': 'm1',
        'conversationId': 'conv',
        'kind': 'from-the-future',
        'status': 'teleported',
        'createdAt': '2026-02-03T04:05:06.000Z',
      });

      expect(restored.kind, MessageKind.text);
      expect(restored.status, MessageStatus.sent);
      expect(restored.senderId, '');
      expect(restored.deleted, isFalse);
      expect(restored.outgoing, isFalse);
    });

    test('missing required fields throw, because that is a corrupted box', () {
      expect(() => ChatMessage.fromMap({}), throwsA(anything));
    });
  });

  group('ChatMessage.effectiveStatus', () {
    test('read beats delivered beats whatever the local status was', () {
      final now = DateTime.utc(2026, 1, 1);
      expect(
        message(status: MessageStatus.sending, deliveredAt: now, readAt: now).effectiveStatus,
        MessageStatus.read,
      );
      expect(
        message(status: MessageStatus.sending, deliveredAt: now).effectiveStatus,
        MessageStatus.delivered,
      );
      expect(message(status: MessageStatus.sending).effectiveStatus, MessageStatus.sending);
    });

    test('a deleted message reports its own status, not the tick state', () {
      final deleted = message(
        status: MessageStatus.failed,
        deleted: true,
        deliveredAt: DateTime.utc(2026, 1, 1),
        readAt: DateTime.utc(2026, 1, 1),
      );

      expect(deleted.effectiveStatus, MessageStatus.failed);
    });
  });

  group('ChatMessage.copyWith', () {
    test('updates the mutable fields and keeps identity', () {
      final base = message();
      final updated = base.copyWith(
        seq: 12,
        envelope: 'enc2',
        text: 'edited',
        status: MessageStatus.read,
        deleted: true,
        failedReason: 'boom',
      );

      expect(updated.seq, 12);
      expect(updated.envelope, 'enc2');
      expect(updated.text, 'edited');
      expect(updated.status, MessageStatus.read);
      expect(updated.deleted, isTrue);
      expect(updated.failedReason, 'boom');
      expect(updated.uuid, base.uuid);
      expect(updated.clientId, base.clientId);
      expect(updated.createdAt, base.createdAt);
      expect(updated.kind, base.kind);
    });

    test('an explicit zero seq is kept', () {
      expect(message().copyWith(seq: 0).seq, 0);
    });

    test('omitted fields are unchanged', () {
      final base = message(deliveredAt: DateTime.utc(2026, 1, 1));
      final copy = base.copyWith(text: 'x');

      expect(copy.deliveredAt, base.deliveredAt);
      expect(copy.envelope, base.envelope);
      expect(copy.status, base.status);
    });
  });

  group('EnvelopeBody', () {
    test('encodes and decodes every field', () {
      const body = EnvelopeBody(
        text: 'hi',
        media: MediaAttachment(id: 'm1', mimeType: 'image/png', sizeBytes: 3, keyBase64: 'k'),
        catalog: CatalogSnapshot(itemId: 'i1', name: 'Tea', priceLabel: '€1'),
        action: 'auto-reply',
        replyPreview: 'previous',
      );

      final decoded = EnvelopeBody.decode(body.encode());

      expect(decoded.text, 'hi');
      expect(decoded.media?.id, 'm1');
      expect(decoded.media?.keyBase64, 'k');
      expect(decoded.catalog?.name, 'Tea');
      expect(decoded.action, 'auto-reply');
      expect(decoded.replyPreview, 'previous');
    });

    test('omits absent fields instead of writing nulls', () {
      const body = EnvelopeBody(text: 'only text');
      final json = jsonDecode(body.encode()) as Map<String, dynamic>;

      expect(json, {'text': 'only text'});
      expect(const EnvelopeBody().encode(), '{}');
    });

    test('decodes a body that only has unknown keys as empty', () {
      final decoded = EnvelopeBody.decode('{"future":"field"}');

      expect(decoded.text, isNull);
      expect(decoded.media, isNull);
      expect(decoded.catalog, isNull);
      expect(decoded.action, isNull);
    });

    test('decoded text survives unicode and quotes', () {
      const text = 'Ünïcode — "quoted" \n next line';
      expect(EnvelopeBody.decode(EnvelopeBody(text: text).encode()).text, text);
    });
  });

  group('QuickReply', () {
    test('survives a JSON round trip', () {
      const original = QuickReply(id: 'q1', shortcut: '/address', title: 'Address', body: 'Main St 1');
      final restored = QuickReply.fromJson(original.toJson());

      expect(restored.id, 'q1');
      expect(restored.shortcut, '/address');
      expect(restored.title, 'Address');
      expect(restored.body, 'Main St 1');
    });

    test('defaults title to the shortcut, then to empty', () {
      expect(QuickReply.fromJson({'id': 'q', 'shortcut': '/hi'}).title, '/hi');
      expect(QuickReply.fromJson({'id': 'q'}).shortcut, '');
      expect(QuickReply.fromJson({'id': 'q'}).title, '');
      expect(QuickReply.fromJson({'id': 'q'}).body, '');
    });

    test('copyWith keeps the id', () {
      const base = QuickReply(id: 'q1', shortcut: '/a', title: 'A', body: 'body');
      final updated = base.copyWith(body: 'new body');

      expect(updated.id, 'q1');
      expect(updated.body, 'new body');
      expect(updated.shortcut, '/a');
    });
  });

  group('LabelTag', () {
    test('survives a JSON round trip using the wire name "color"', () {
      const original = LabelTag(id: 'l1', name: 'VIP', colorHex: '#FF0000');
      final json = original.toJson();

      expect(json['color'], '#FF0000');
      final restored = LabelTag.fromJson(json);
      expect(restored.id, 'l1');
      expect(restored.name, 'VIP');
      expect(restored.colorHex, '#FF0000');
    });

    test('defaults name to empty and colour to the app indigo', () {
      final parsed = LabelTag.fromJson({'id': 'l1'});

      expect(parsed.name, '');
      expect(parsed.colorHex, '#6366F1');
    });
  });

  group('CatalogItem', () {
    test('survives a JSON round trip including inactive items', () {
      const original = CatalogItem(
        id: 'i1',
        name: 'Coffee',
        priceCents: 250,
        currency: 'USD',
        description: 'Flat white',
        imageMediaId: 'media-9',
        active: false,
      );
      final restored = CatalogItem.fromJson(original.toJson());

      expect(restored.id, 'i1');
      expect(restored.name, 'Coffee');
      expect(restored.priceCents, 250);
      expect(restored.currency, 'USD');
      expect(restored.description, 'Flat white');
      expect(restored.imageMediaId, 'media-9');
      expect(restored.active, isFalse);
    });

    test('defaults currency, price and active for a thin payload', () {
      final parsed = CatalogItem.fromJson({'id': 'i1'});

      expect(parsed.name, '');
      expect(parsed.priceCents, 0);
      expect(parsed.currency, 'EUR');
      expect(parsed.active, isTrue);
    });

    test('priceLabel formats known currencies, whole and fractional', () {
      String label(int cents, String currency) =>
          CatalogItem(id: 'i', name: 'n', priceCents: cents, currency: currency).priceLabel;

      expect(label(250, 'EUR'), '€2.50');
      expect(label(200, 'EUR'), '€2');
      expect(label(1999, 'USD'), r'$19.99');
      expect(label(500, 'GBP'), '£5');
      expect(label(15000, 'IDR'), 'Rp150');
      expect(label(100, 'INR'), '₹1');
      expect(label(250, 'CHF'), 'CHF 2.50');
      expect(label(5, 'EUR'), '€0.05');
    });

    test('toSnapshot carries the formatted price and media id', () {
      const item = CatalogItem(
        id: 'i1',
        name: 'Tea',
        priceCents: 300,
        currency: 'GBP',
        description: 'Earl Grey',
        imageMediaId: 'media-3',
      );

      final snapshot = item.toSnapshot();

      expect(snapshot.itemId, 'i1');
      expect(snapshot.name, 'Tea');
      expect(snapshot.priceLabel, '£3');
      expect(snapshot.description, 'Earl Grey');
      expect(snapshot.imageMediaId, 'media-3');
    });
  });

  group('AwaySchedule', () {
    test('a daytime range includes start and excludes end', () {
      const schedule = AwaySchedule(startHour: 9, endHour: 17);

      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 8)), isFalse);
      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 9)), isTrue);
      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 16)), isTrue);
      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 17)), isFalse);
      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 23)), isFalse);
    });

    test('an overnight range wraps midnight', () {
      const schedule = AwaySchedule(startHour: 22, endHour: 7);

      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 21)), isFalse);
      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 22)), isTrue);
      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 23)), isTrue);
      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 0)), isTrue);
      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 6)), isTrue);
      expect(schedule.isActiveAt(DateTime(2026, 1, 1, 7)), isFalse);
    });

    test('equal start and end means never away', () {
      const schedule = AwaySchedule(startHour: 0, endHour: 0);

      for (var hour = 0; hour < 24; hour++) {
        expect(schedule.isActiveAt(DateTime(2026, 1, 1, hour)), isFalse);
      }
    });

    test('round trips and defaults to 22:00-07:00', () {
      const original = AwaySchedule(startHour: 8, endHour: 18);
      final restored = AwaySchedule.fromJson(original.toJson());
      final fallback = AwaySchedule.fromJson({});

      expect(restored.startHour, 8);
      expect(restored.endHour, 18);
      expect(fallback.startHour, 22);
      expect(fallback.endHour, 7);
    });

    test('label zero-pads both ends', () {
      expect(const AwaySchedule(startHour: 8, endHour: 18).label, '08:00 – 18:00');
      expect(const AwaySchedule().label, '22:00 – 07:00');
    });
  });

  group('AutoReplySettings', () {
    test('survives a JSON round trip with the nested schedule', () {
      const original = AutoReplySettings(
        greetingEnabled: true,
        greetingText: 'Hi there',
        awayEnabled: true,
        awayText: 'Gone',
        awaySchedule: AwaySchedule(startHour: 18, endHour: 9),
        cooldownHours: 4,
      );
      final restored = AutoReplySettings.fromJson(jsonDecode(jsonEncode(original.toJson())));

      expect(restored.greetingEnabled, isTrue);
      expect(restored.greetingText, 'Hi there');
      expect(restored.awayEnabled, isTrue);
      expect(restored.awayText, 'Gone');
      expect(restored.awaySchedule.startHour, 18);
      expect(restored.awaySchedule.endHour, 9);
      expect(restored.cooldownHours, 4);
    });

    test('defaults everything when the payload is empty', () {
      final parsed = AutoReplySettings.fromJson({});

      expect(parsed.greetingEnabled, isFalse);
      expect(parsed.awayEnabled, isFalse);
      expect(parsed.greetingText, isEmpty);
      expect(parsed.awayText, isEmpty);
      expect(parsed.awaySchedule.startHour, 22);
      expect(parsed.cooldownHours, 8);
    });

    test('a section that is not a map is ignored', () {
      final parsed = AutoReplySettings.fromJson({'greeting': 'on', 'away': 42});

      expect(parsed.greetingEnabled, isFalse);
      expect(parsed.greetingText, isEmpty);
      expect(parsed.awayEnabled, isFalse);
      expect(parsed.cooldownHours, 8);
    });

    test('a schedule that is not a map falls back to the default window', () {
      final parsed = AutoReplySettings.fromJson({
        'away': {'enabled': true, 'schedule': 'around dinner'},
      });

      expect(parsed.awayEnabled, isTrue);
      expect(parsed.awaySchedule.startHour, 22);
      expect(parsed.awaySchedule.endHour, 7);
    });

    test('copyWith with no arguments is an exact copy', () {
      const base = AutoReplySettings(
        greetingEnabled: true,
        awayEnabled: true,
        cooldownHours: 2,
        awaySchedule: AwaySchedule(startHour: 3, endHour: 4),
      );

      expect(base.copyWith().toJson(), base.toJson());
    });

    test('copyWith replaces only what it is given', () {
      const base = AutoReplySettings(greetingEnabled: true, cooldownHours: 3);
      final updated = base.copyWith(awayEnabled: true, awaySchedule: const AwaySchedule(startHour: 1, endHour: 2));

      expect(updated.awayEnabled, isTrue);
      expect(updated.awaySchedule.startHour, 1);
      expect(updated.greetingEnabled, isTrue);
      expect(updated.cooldownHours, 3);
      expect(updated.greetingText, base.greetingText);
    });
  });

  group('ServerEndpoint', () {
    test('marks wss and https secure, ws and http not', () {
      expect(const ServerEndpoint(url: 'wss://x/y', kind: EndpointKind.public).isSecure, isTrue);
      expect(const ServerEndpoint(url: 'https://x', kind: EndpointKind.public).isSecure, isTrue);
      expect(const ServerEndpoint(url: 'ws://x', kind: EndpointKind.lan).isSecure, isFalse);
      expect(const ServerEndpoint(url: 'http://x', kind: EndpointKind.lan).isSecure, isFalse);
    });

    test('only lan and loopback count as local', () {
      expect(const ServerEndpoint(url: 'u', kind: EndpointKind.lan).isLocal, isTrue);
      expect(const ServerEndpoint(url: 'u', kind: EndpointKind.loopback).isLocal, isTrue);
      expect(const ServerEndpoint(url: 'u', kind: EndpointKind.tailnet).isLocal, isFalse);
      expect(const ServerEndpoint(url: 'u', kind: EndpointKind.public).isLocal, isFalse);
    });

    test('httpBase converts the scheme and strips trailing slashes', () {
      expect(const ServerEndpoint(url: 'ws://192.168.0.5:8787', kind: EndpointKind.lan).httpBase,
          'http://192.168.0.5:8787');
      expect(const ServerEndpoint(url: 'wss://chat.example.com/', kind: EndpointKind.public).httpBase,
          'https://chat.example.com');
      expect(const ServerEndpoint(url: 'wss://chat.example.com///', kind: EndpointKind.public).httpBase,
          'https://chat.example.com');
    });

    test('socketBase maps back to the ws scheme and is stable on repeat', () {
      const endpoint = ServerEndpoint(url: 'wss://chat.example.com', kind: EndpointKind.public);

      expect(endpoint.socketBase, 'wss://chat.example.com');
      expect(endpoint.socketBase, 'wss://chat.example.com');
      expect(const ServerEndpoint(url: 'ws://10.0.0.2:3000', kind: EndpointKind.lan).socketBase,
          'ws://10.0.0.2:3000');
    });

    test('toString names the kind so logs are readable', () {
      expect(const ServerEndpoint(url: 'wss://x', kind: EndpointKind.tailnet).toString(), 'EndpointKind.tailnet:wss://x');
    });
  });

  group('ConnectionInfo', () {
    test('online and degraded both count as connected', () {
      expect(const ConnectionInfo(status: ConnectionStatus.online).isOnline, isTrue);
      expect(const ConnectionInfo(status: ConnectionStatus.degraded).isOnline, isTrue);
      expect(const ConnectionInfo(status: ConnectionStatus.offline).isOnline, isFalse);
      expect(const ConnectionInfo(status: ConnectionStatus.probing).isOnline, isFalse);
      expect(const ConnectionInfo(status: ConnectionStatus.connecting).isOnline, isFalse);
    });

    test('label distinguishes Wi-Fi from elsewhere, and covers every status', () {
      const lan = ServerEndpoint(url: 'ws://192.168.0.5', kind: EndpointKind.lan);
      const remote = ServerEndpoint(url: 'wss://chat.example.com', kind: EndpointKind.public);

      expect(const ConnectionInfo(status: ConnectionStatus.online, endpoint: lan).label, 'On your Wi-Fi');
      expect(const ConnectionInfo(status: ConnectionStatus.online, endpoint: remote).label, 'Connected');
      expect(const ConnectionInfo(status: ConnectionStatus.degraded).label, 'Weak connection');
      expect(const ConnectionInfo(status: ConnectionStatus.connecting).label, 'Connecting…');
      expect(const ConnectionInfo(status: ConnectionStatus.probing).label, 'Finding server…');
      expect(const ConnectionInfo(status: ConnectionStatus.offline).label, 'Offline — showing cached messages');
    });

    test('defaults are unused-but-safe', () {
      const info = ConnectionInfo(status: ConnectionStatus.offline);

      expect(info.endpoint, isNull);
      expect(info.rttMs, isNull);
      expect(info.peerOnline, isFalse);
      expect(info.lastError, isNull);
    });
  });

  group('parseHexColor', () {
    test('accepts with and without the hash', () {
      expect(parseHexColor('#FF0000'), 0xFF0000);
      expect(parseHexColor('00ff00'), 0x00FF00);
      expect(parseHexColor('#4F46E5'), 0x4F46E5);
    });

    test('falls back to the app indigo on anything unparseable', () {
      expect(parseHexColor(''), 0x4F46E5);
      expect(parseHexColor('#zzzzzz'), 0x4F46E5);
      expect(parseHexColor('not a colour'), 0x4F46E5);
    });
  });

  group('formatRelative', () {
    final now = DateTime.utc(2026, 5, 10, 12);

    String rel(DateTime time) => formatRelative(time, now: now);

    test('under a minute reads "now", including future timestamps', () {
      expect(rel(now), 'now');
      expect(rel(now.subtract(const Duration(seconds: 59))), 'now');
      expect(rel(now.add(const Duration(minutes: 5))), 'now');
    });

    test('defaults to the current clock when no reference is given', () {
      final realNow = DateTime.now();

      expect(formatRelative(realNow.subtract(const Duration(hours: 3))), '3h');
      expect(formatRelative(realNow.subtract(const Duration(days: 2))), '2d');
    });

    test('minutes, hours, yesterday, days, then a date', () {
      expect(rel(now.subtract(const Duration(minutes: 1))), '1m');
      expect(rel(now.subtract(const Duration(minutes: 59))), '59m');
      expect(rel(now.subtract(const Duration(hours: 1))), '1h');
      expect(rel(now.subtract(const Duration(hours: 23))), '23h');
      expect(rel(now.subtract(const Duration(days: 1))), 'yesterday');
      expect(rel(now.subtract(const Duration(days: 2))), '2d');
      expect(rel(now.subtract(const Duration(days: 6))), '6d');
      expect(rel(DateTime.utc(2026, 4, 3, 12)), '3/4');
    });
  });

  group('formatClock', () {
    test('zero-pads to HH:mm in local time', () {
      expect(formatClock(DateTime(2026, 1, 1, 9, 5)), '09:05');
      expect(formatClock(DateTime(2026, 1, 1, 0, 0)), '00:00');
      expect(formatClock(DateTime(2026, 1, 1, 23, 59)), '23:59');
    });
  });

  group('formatBytes', () {
    test('bytes, kilobytes and megabytes with one decimal', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024 - 1), '1024.0 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(5 * 1024 * 1024 + 512 * 1024), '5.5 MB');
    });
  });

  group('clampDouble', () {
    test('clamps below, inside and above the range', () {
      expect(clampDouble(-5, 0, 1), 0);
      expect(clampDouble(0.25, 0, 1), 0.25);
      expect(clampDouble(7, 0, 1), 1);
      expect(clampDouble(0, 0, 1), 0);
      expect(clampDouble(1, 0, 1), 1);
    });
  });
}
