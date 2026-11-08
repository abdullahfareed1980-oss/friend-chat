import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:friend_chat/data/local_store.dart';
import 'package:friend_chat/models/models.dart';

/// The store is a singleton over three Hive boxes, so these tests open it once
/// into a temporary directory and empty it between tests. `open()` takes an
/// optional path for exactly this: `path_provider` is not available here.
///
/// The boxes are really encrypted (`HiveAesCipher`), so these tests also prove
/// the round trip the app performs on every launch.
LocalStore get store => LocalStore.instance;

ChatMessage _message({
  required String uuid,
  required String conversationId,
  required DateTime createdAt,
  int seq = 0,
  String? clientId,
  String? text,
}) =>
    ChatMessage(
      uuid: uuid,
      clientId: clientId ?? 'client-$uuid',
      conversationId: conversationId,
      senderId: 'me',
      createdAt: createdAt,
      kind: MessageKind.text,
      seq: seq,
      text: text ?? 'body-$uuid',
    );

void main() {
  // The last test answers the `path_provider` channel by hand, which needs the
  // binary messenger to exist.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('fc_local_store_');
    await store.open(
      Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      path: dir.path,
    );
  });

  setUp(() async {
    await store.clearAll();
  });

  tearDownAll(() async {
    await store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('opens and reports it', () {
    expect(store.isOpen, isTrue);
  });

  group('messages', () {
    test('put/get by uuid and by client id', () async {
      final message = _message(
        uuid: 'a',
        conversationId: 'c1',
        createdAt: DateTime(2026),
        clientId: 'cli-a',
      );

      await store.put(message);

      expect(store.messageByUuid('a')!.text, 'body-a');
      expect(store.messageByClientId('cli-a')!.uuid, 'a');
      expect(store.messageByUuid('missing'), isNull);
      expect(store.messageByClientId('nope'), isNull);
    });

    test('messagesFor filters by conversation and sorts by seq', () async {
      final base = DateTime(2026, 1, 1);
      await store.put(_message(uuid: 'b', conversationId: 'c1', createdAt: base, seq: 2));
      await store.put(_message(uuid: 'a', conversationId: 'c1', createdAt: base, seq: 1));
      await store.put(_message(uuid: 'c', conversationId: 'c2', createdAt: base, seq: 3));

      final c1 = store.messagesFor('c1');

      expect(c1.map((m) => m.uuid), ['a', 'b']);
      expect(store.messagesFor('nobody'), isEmpty);
    });

    test('messagesFor falls back to createdAt when seq is unset', () async {
      // Outbox entries have no server cursor yet, so they have to sort on the
      // clock instead. Sequencing and non-sequenced messages are not mixed here:
      // the comparator would then be intransitive, and pinning one of its
      // outcomes would be pinning an artefact rather than a promise.
      await store.put(_message(uuid: 'late', conversationId: 'c1', createdAt: DateTime(2026, 5)));
      await store.put(_message(uuid: 'early', conversationId: 'c1', createdAt: DateTime(2026, 2)));

      expect(store.messagesFor('c1').map((m) => m.uuid), ['early', 'late']);
    });

    test('putAll writes a batch', () async {
      await store.putAll([
        _message(uuid: 'x', conversationId: 'c1', createdAt: DateTime(2026)),
        _message(uuid: 'y', conversationId: 'c1', createdAt: DateTime(2026)),
      ]);

      expect(store.messagesFor('c1').length, 2);
    });

    test('delete removes the message and its cursor entry', () async {
      await store.put(_message(uuid: 'd', conversationId: 'c1', createdAt: DateTime(2026), seq: 42));
      expect(store.cursor, 42);

      await store.delete('d');

      expect(store.messageByUuid('d'), isNull);
      expect(store.cursor, 0);

      // Deleting something that was never stored must not throw.
      await store.delete('ghost');
    });
  });

  group('cursor', () {
    test('prefers the stored value, then the highest seq', () async {
      expect(store.cursor, 0);

      await store.put(_message(uuid: 's1', conversationId: 'c1', createdAt: DateTime(2026), seq: 5));
      expect(store.cursor, 5);

      await store.setCursor(9);
      expect(store.cursor, 9);
    });

    test('a stored non-int value falls through to the seq index', () async {
      await store.put(_message(uuid: 's1', conversationId: 'c1', createdAt: DateTime(2026), seq: 4));
      await store.writeMeta('cursor', 'not an int');

      expect(store.cursor, 4);
    });
  });

  group('meta', () {
    test('reads typed values, including a type mismatch', () async {
      expect(store.readMeta<String>('token'), isNull);

      await store.writeMeta('token', 'abc');
      expect(store.readMeta<String>('token'), 'abc');
      expect(store.readMeta<int>('token'), isNull);
    });

    test('reads maps, including a shape that is not a map', () async {
      expect(store.readMetaMap('revs'), isNull);

      await store.writeMeta('revs', {'docs': 3});
      expect(store.readMetaMap('revs'), {'docs': 3});

      await store.writeMeta('revs', 'broken');
      expect(store.readMetaMap('revs'), isNull);
    });

    test('reads lists, filtering entries that are not maps', () async {
      expect(store.readMetaList('drafts'), isEmpty);

      await store.writeMetaList('drafts', [
        {'id': 1},
        {'id': 2},
      ]);
      expect(store.readMetaList('drafts'), [
        {'id': 1},
        {'id': 2},
      ]);

      await store.writeMeta('drafts', [
        {'id': 3},
        'junk',
      ]);
      expect(store.readMetaList('drafts'), [
        {'id': 3},
      ]);

      await store.writeMeta('drafts', 'not a list');
      expect(store.readMetaList('drafts'), isEmpty);
    });

    test('removeMeta deletes the key', () async {
      await store.writeMeta('temp', 1);

      await store.removeMeta('temp');

      expect(store.readMeta<int>('temp'), isNull);
    });
  });

  test('exportJson carries the cursor and the conversation', () async {
    await store.writeMeta('conversationId', 'c1');
    await store.put(_message(uuid: 'e', conversationId: 'c1', createdAt: DateTime(2026), seq: 3));

    final payload = jsonDecode(store.exportJson()) as Map<String, dynamic>;

    expect(payload['cursor'], 3);
    expect((payload['messages'] as List).single['uuid'], 'e');
    expect(DateTime.tryParse(payload['exportedAt'] as String), isNotNull);
  });

  test('exportJson with no conversation stored exports an empty list', () async {
    final payload = jsonDecode(store.exportJson()) as Map<String, dynamic>;

    expect(payload['messages'], isEmpty);
  });

  // Last on purpose: it closes the boxes the tests above used. The app opens the
  // store with no path and lets Hive ask `path_provider`; here that plugin is not
  // registered, so the channel it would call is answered by hand.
  test('open without a path asks the platform for a directory', () async {
    await store.close();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method.contains('getApplicationDocuments')
          ? dir.path
          : throw MissingPluginException(call.method),
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    });

    await store.open(
      Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
    );

    expect(store.isOpen, isTrue);
  });
}
