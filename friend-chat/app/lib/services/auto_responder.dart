import 'dart:async';

import '../data/meta_store.dart';
import '../models/models.dart';

/// ---------------------------------------------------------------------------
/// Client-side auto-responder.
///
/// This deliberately runs on the device, never on the server: the server has no
/// plaintext, so it could not compose a greeting even if it wanted to. The
/// foreground service keeps the process alive so replies still go out while the
/// app sits in the background.
/// ---------------------------------------------------------------------------
class AutoResponder {
  AutoReplySettings settings = const AutoReplySettings();

  static const _settingsKey = 'autoReply';
  static String _lastKey(String kind) => 'autoReplyLast_$kind';

  Future<void> load(MetaStore store) async {
    final map = store.readMetaMap(_settingsKey);
    if (map != null) settings = AutoReplySettings.fromJson(map);
  }

  Future<void> save(MetaStore store, AutoReplySettings next) async {
    settings = next;
    await store.writeMeta(_settingsKey, next.toJson());
  }

  /// Returns the text to send back, or null when silence is the right answer.
  ///
  /// * away  - fires whenever the away schedule covers "now"
  /// * greeting - fires only for a conversation that has been quiet for a while
  ///
  /// Both respect the per-kind cooldown so the peer never gets a robotic reply
  /// to every single message.
  Future<String?> decide({
    required DateTime now,
    required bool conversationRestarted,
    required MetaStore store,
  }) async {
    if (settings.awayEnabled &&
        settings.awaySchedule.isActiveAt(now) &&
        settings.awayText.trim().isNotEmpty &&
        await _cooldownPassed(store, 'away', now)) {
      await _stamp(store, 'away', now);
      return settings.awayText;
    }

    if (settings.greetingEnabled &&
        conversationRestarted &&
        settings.greetingText.trim().isNotEmpty &&
        await _cooldownPassed(store, 'greeting', now)) {
      await _stamp(store, 'greeting', now);
      return settings.greetingText;
    }

    return null;
  }

  Future<bool> _cooldownPassed(MetaStore store, String kind, DateTime now) async {
    final raw = store.readMeta<String>(_lastKey(kind));
    if (raw == null) return true;
    final last = DateTime.tryParse(raw);
    if (last == null) return true;
    return now.difference(last).inHours >= settings.cooldownHours;
  }

  Future<void> _stamp(MetaStore store, String kind, DateTime now) =>
      store.writeMeta(_lastKey(kind), now.toIso8601String());

  /// Shown in the Business tab summary card.
  String get statusLine {
    if (settings.awayEnabled && settings.greetingEnabled) {
      return 'Greeting + away replies on (${settings.awaySchedule.label})';
    }
    if (settings.awayEnabled) return 'Away replies on (${settings.awaySchedule.label})';
    if (settings.greetingEnabled) return 'Greeting on';
    return 'Automation off';
  }
}
