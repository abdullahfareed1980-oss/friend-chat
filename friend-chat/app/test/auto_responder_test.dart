import 'package:flutter_test/flutter_test.dart';
import 'package:friend_chat/data/meta_store.dart';
import 'package:friend_chat/models/models.dart';
import 'package:friend_chat/services/auto_responder.dart';

/// In-memory [MetaStore]. The auto-responder only ever touches settings and the
/// per-kind "last replied at" stamps, so a map is the whole dependency — no Hive
/// box, no encryption key, no plugin channel.
class _FakeMetaStore implements MetaStore {
  _FakeMetaStore([Map<String, Object?>? seed]) : values = {...?seed};

  final Map<String, Object?> values;
  final List<String> written = [];

  @override
  T? readMeta<T>(String key) {
    final value = values[key];
    return value is T ? value : null;
  }

  @override
  Map<String, dynamic>? readMetaMap(String key) {
    final value = values[key];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  @override
  Future<void> writeMeta(String key, Object? value) async {
    values[key] = value;
    written.add(key);
  }
}

const _awayText = 'Away until 9.';
const _greetingText = 'Hi! Back at my desk shortly.';

/// 23:00 is inside the default 22:00–07:00 away window.
final _insideWindow = DateTime(2026, 11, 8, 23, 0);
final _outsideWindow = DateTime(2026, 11, 8, 12, 0);

AutoResponder _responder({
  bool awayEnabled = false,
  bool greetingEnabled = false,
  String awayText = _awayText,
  String greetingText = _greetingText,
  int cooldownHours = 8,
}) =>
    AutoResponder()
      ..settings = AutoReplySettings(
        awayEnabled: awayEnabled,
        awayText: awayText,
        greetingEnabled: greetingEnabled,
        greetingText: greetingText,
        cooldownHours: cooldownHours,
      );

void main() {
  group('settings persistence', () {
    test('load keeps the defaults when nothing is stored', () async {
      final responder = AutoResponder();
      await responder.load(_FakeMetaStore());

      expect(responder.settings.awayEnabled, isFalse);
      expect(responder.settings.cooldownHours, 8);
      expect(responder.settings.greetingText, isNotEmpty);
    });

    test('load applies stored settings', () async {
      final store = _FakeMetaStore({
        'autoReply': const AutoReplySettings(
          awayEnabled: true,
          awayText: 'Stored away text',
          cooldownHours: 2,
        ).toJson(),
      });
      final responder = AutoResponder()..settings = const AutoReplySettings();

      await responder.load(store);

      expect(responder.settings.awayEnabled, isTrue);
      expect(responder.settings.awayText, 'Stored away text');
      expect(responder.settings.cooldownHours, 2);
    });

    test('save stores the settings and adopts them', () async {
      final store = _FakeMetaStore();
      final responder = AutoResponder();
      const next = AutoReplySettings(greetingEnabled: true, greetingText: 'Yo');

      await responder.save(store, next);

      expect(responder.settings.greetingEnabled, isTrue);
      expect(store.written, ['autoReply']);
      final stored = store.readMetaMap('autoReply')!;
      expect(AutoReplySettings.fromJson(stored).greetingText, 'Yo');
    });
  });

  group('away replies', () {
    test('fires once inside the window and stamps the cooldown', () async {
      final store = _FakeMetaStore();
      final responder = _responder(awayEnabled: true);

      final reply = await responder.decide(
        now: _insideWindow,
        conversationRestarted: false,
        store: store,
      );

      expect(reply, _awayText);
      expect(store.readMeta<String>('autoReplyLast_away'),
          _insideWindow.toIso8601String());
    });

    test('stays silent outside the window', () async {
      final responder = _responder(awayEnabled: true);

      final reply = await responder.decide(
        now: _outsideWindow,
        conversationRestarted: true,
        store: _FakeMetaStore(),
      );

      expect(reply, isNull);
    });

    test('stays silent when the away text is blank', () async {
      final responder = _responder(awayEnabled: true, awayText: '   ');

      final reply = await responder.decide(
        now: _insideWindow,
        conversationRestarted: true,
        store: _FakeMetaStore(),
      );

      expect(reply, isNull);
    });

    test('respects the cooldown, then replies again once it lapses', () async {
      final stamp = _insideWindow.subtract(const Duration(hours: 1));
      final store = _FakeMetaStore({
        'autoReplyLast_away': stamp.toIso8601String(),
      });
      final responder = _responder(awayEnabled: true);

      expect(
        await responder.decide(
          now: _insideWindow,
          conversationRestarted: true,
          store: store,
        ),
        isNull,
      );

      // Same hour next day: inside the away window, and past the 8 h cooldown.
      final later = _insideWindow.add(const Duration(hours: 24));
      expect(
        await responder.decide(
          now: later,
          conversationRestarted: true,
          store: store,
        ),
        _awayText,
      );
    });

    test('an unreadable stamp is treated as no cooldown', () async {
      final store = _FakeMetaStore({'autoReplyLast_away': 'not a date'});
      final responder = _responder(awayEnabled: true);

      expect(
        await responder.decide(
          now: _insideWindow,
          conversationRestarted: true,
          store: store,
        ),
        _awayText,
      );
    });
  });

  group('greeting replies', () {
    test('only fires when the conversation restarted', () async {
      final responder = _responder(greetingEnabled: true);

      expect(
        await responder.decide(
          now: _insideWindow,
          conversationRestarted: false,
          store: _FakeMetaStore(),
        ),
        isNull,
      );
      expect(
        await responder.decide(
          now: _insideWindow,
          conversationRestarted: true,
          store: _FakeMetaStore(),
        ),
        _greetingText,
      );
    });

    test('stays silent when the greeting text is blank', () async {
      final responder = _responder(greetingEnabled: true, greetingText: ' ');

      expect(
        await responder.decide(
          now: _insideWindow,
          conversationRestarted: true,
          store: _FakeMetaStore(),
        ),
        isNull,
      );
    });

    test('keeps its own cooldown, separate from the away stamp', () async {
      final store = _FakeMetaStore({
        'autoReplyLast_away': _insideWindow.toIso8601String(),
      });
      final responder = _responder(greetingEnabled: true);

      // The away stamp must not suppress the greeting.
      expect(
        await responder.decide(
          now: _insideWindow,
          conversationRestarted: true,
          store: store,
        ),
        _greetingText,
      );
      expect(store.readMeta<String>('autoReplyLast_greeting'), isNotNull);

      expect(
        await responder.decide(
          now: _insideWindow.add(const Duration(minutes: 5)),
          conversationRestarted: true,
          store: store,
        ),
        isNull,
      );
    });
  });

  test('away wins over greeting when both are due', () async {
    final store = _FakeMetaStore();
    final responder = _responder(awayEnabled: true, greetingEnabled: true);

    final reply = await responder.decide(
      now: _insideWindow,
      conversationRestarted: true,
      store: store,
    );

    expect(reply, _awayText);
    expect(store.written, ['autoReplyLast_away']);
  });

  test('returns null when no automation is enabled', () async {
    final reply = await _responder().decide(
      now: _insideWindow,
      conversationRestarted: true,
      store: _FakeMetaStore(),
    );

    expect(reply, isNull);
  });

  group('statusLine', () {
    test('describes each combination', () {
      expect(_responder().statusLine, 'Automation off');
      expect(
        _responder(greetingEnabled: true).statusLine,
        'Greeting on',
      );
      expect(
        _responder(awayEnabled: true).statusLine,
        'Away replies on (22:00 – 07:00)',
      );
      expect(
        _responder(awayEnabled: true, greetingEnabled: true).statusLine,
        'Greeting + away replies on (22:00 – 07:00)',
      );
    });
  });
}
