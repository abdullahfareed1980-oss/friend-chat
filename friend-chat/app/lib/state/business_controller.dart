import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/local_store.dart';
import '../data/rest_client.dart';
import '../models/models.dart';
import '../services/auto_responder.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Business tooling: quick replies, catalog, labels, auto messages.
///
/// These documents are intentionally *not* end-to-end encrypted - a catalog has
/// to be enumerable by the peer's app and a label has to survive a reinstall.
/// They contain only business metadata, never conversation content.
/// ---------------------------------------------------------------------------

class BusinessController extends ChangeNotifier {
  BusinessController({required this.api, required this.store, required this.autoResponder});

  ApiClient? api;
  final LocalStore store;
  final AutoResponder autoResponder;

  List<QuickReply> quickReplies = const [];
  List<CatalogItem> catalog = const [];
  List<LabelTag> labels = const [];
  List<CatalogItem> peerCatalog = const [];

  Map<String, int> _revs = const {};
  Set<String> conversationLabels = {};
  bool loading = false;
  String? error;

  AutoReplySettings get autoReply => autoResponder.settings;

  /// One-line summary shown on the home screen and the business hub.
  String get autoReplyLine {
    final prefs = autoResponder.settings;
    final parts = <String>[
      if (prefs.greetingEnabled) 'Greeting on',
      if (prefs.awayEnabled) 'Away ${prefs.awaySchedule.label}',
    ];
    return parts.isEmpty ? 'Automation off' : parts.join(' · ');
  }

  /// Labels currently attached to the single conversation.
  List<LabelTag> get activeLabels =>
      labels.where((label) => conversationLabels.contains(label.id)).toList();

  Future<void> load() async {
    loading = true;
    notifyListeners();

    // Cache first so the Business tab is useful offline.
    _hydrateFromCache();
    conversationLabels = (store.readMeta<String>('labelsForConversation') ?? '')
        .split(',')
        .where((e) => e.isNotEmpty)
        .toSet();
    await autoResponder.load(store);

    try {
      final client = api;
      if (client != null) {
        for (final section in const ['quick_replies', 'catalog', 'labels', 'auto_reply']) {
          final doc = await client.businessDoc(section);
          _applyDoc(section, doc, persist: true);
        }
        final peer = await client.peerCatalog();
        peerCatalog = ((peer['items'] as List?) ?? const [])
            .map((e) => CatalogItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
      error = null;
    } catch (err) {
      error = '$err';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void _hydrateFromCache() {
    quickReplies = store
        .readMetaList('quick_replies')
        .map(QuickReply.fromJson)
        .toList();
    catalog = store.readMetaList('catalog').map(CatalogItem.fromJson).toList();
    labels = store.readMetaList('labels').map(LabelTag.fromJson).toList();
    final revs = store.readMetaMap('businessRevs') ?? const {};
    _revs = revs.map((key, value) => MapEntry(key, value is int ? value : 0));
  }

  void _applyDoc(String section, Map<String, dynamic> doc, {required bool persist}) {
    final payload = (doc['payload'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final rev = (doc['rev'] as num?)?.toInt() ?? 0;
    _revs = {..._revs, section: rev};

    final items = (payload['items'] as List?) ?? const [];
    switch (section) {
      case 'quick_replies':
        quickReplies = items.map((e) => QuickReply.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        if (persist) store.writeMetaList('quick_replies', quickReplies.map((e) => e.toJson()).toList());
      case 'catalog':
        catalog = items.map((e) => CatalogItem.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        if (persist) store.writeMetaList('catalog', catalog.map((e) => e.toJson()).toList());
      case 'labels':
        labels = items.map((e) => LabelTag.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        if (persist) store.writeMetaList('labels', labels.map((e) => e.toJson()).toList());
      case 'auto_reply':
        autoResponder.settings = AutoReplySettings.fromJson(payload);
        if (persist) store.writeMeta('autoReply', payload);
    }
    if (persist) store.writeMeta('businessRevs', _revs);
  }

  Future<void> _push(String section, Map<String, dynamic> payload) async {
    final client = api;
    if (client == null) return;
    try {
      final doc = await client.putBusinessDoc(section, payload, _revs[section] ?? 0);
      _revs = {..._revs, section: (doc['rev'] as num?)?.toInt() ?? 0};
      await store.writeMeta('businessRevs', _revs);
      error = null;
    } on ApiException catch (err) {
      if (err.statusCode == 409) {
        // Someone edited on another device; reload and keep their version.
        final doc = await client.businessDoc(section);
        _applyDoc(section, doc, persist: true);
        error = 'Updated elsewhere — reloaded the latest version.';
      } else {
        error = err.code;
      }
    } catch (err) {
      error = '$err';
    }
    notifyListeners();
  }

  /* ------------------------------------------------------------------ */
  /* Quick replies                                                       */
  /* ------------------------------------------------------------------ */

  Future<void> saveQuickReply(QuickReply reply) async {
    final next = [...quickReplies];
    final index = next.indexWhere((r) => r.id == reply.id);
    if (index >= 0) {
      next[index] = reply;
    } else {
      next.add(reply);
    }
    quickReplies = next;
    notifyListeners();
    await _push('quick_replies', {'items': next.map((e) => e.toJson()).toList()});
  }

  Future<void> deleteQuickReply(String id) async {
    quickReplies = quickReplies.where((r) => r.id != id).toList();
    notifyListeners();
    await _push('quick_replies', {'items': quickReplies.map((e) => e.toJson()).toList()});
  }

  QuickReply newQuickReply() =>
      QuickReply(id: const Uuid().v4(), shortcut: '/new', title: 'New reply', body: '');

  /* ------------------------------------------------------------------ */
  /* Catalog                                                             */
  /* ------------------------------------------------------------------ */

  Future<void> saveCatalogItem(CatalogItem item) async {
    final next = [...catalog];
    final index = next.indexWhere((c) => c.id == item.id);
    if (index >= 0) {
      next[index] = item;
    } else {
      next.add(item);
    }
    catalog = next;
    notifyListeners();
    await _push('catalog', {'items': next.map((e) => e.toJson()).toList()});
  }

  Future<void> deleteCatalogItem(String id) async {
    catalog = catalog.where((c) => c.id != id).toList();
    notifyListeners();
    await _push('catalog', {'items': catalog.map((e) => e.toJson()).toList()});
  }

  CatalogItem newCatalogItem() => CatalogItem(
        id: const Uuid().v4(),
        name: '',
        priceCents: 0,
        currency: 'EUR',
        description: '',
      );

  /* ------------------------------------------------------------------ */
  /* Labels                                                              */
  /* ------------------------------------------------------------------ */

  Future<void> saveLabel(LabelTag label) async {
    final next = [...labels];
    final index = next.indexWhere((l) => l.id == label.id);
    if (index >= 0) {
      next[index] = label;
    } else {
      next.add(label);
    }
    labels = next;
    notifyListeners();
    await _push('labels', {'items': next.map((e) => e.toJson()).toList()});
  }

  Future<void> deleteLabel(String id) async {
    labels = labels.where((l) => l.id != id).toList();
    conversationLabels.remove(id);
    notifyListeners();
    await store.writeMeta('labelsForConversation', conversationLabels.join(','));
    await _push('labels', {'items': labels.map((e) => e.toJson()).toList()});
  }

  Future<void> toggleLabel(String labelId) async {
    if (conversationLabels.contains(labelId)) {
      conversationLabels.remove(labelId);
    } else {
      conversationLabels.add(labelId);
    }
    notifyListeners();
    await store.writeMeta('labelsForConversation', conversationLabels.join(','));
  }

  static const presetLabelColors = <String>[
    '#6366F1',
    '#34D399',
    '#FBBF24',
    '#FB7185',
    '#A78BFA',
    '#38BDF8',
    '#F472B6',
  ];

  LabelTag newLabel() => LabelTag(id: const Uuid().v4(), name: '', colorHex: presetLabelColors.first);

  /* ------------------------------------------------------------------ */
  /* Auto replies                                                        */
  /* ------------------------------------------------------------------ */

  Future<void> saveAutoReply(AutoReplySettings next) async {
    await autoResponder.save(store, next);
    notifyListeners();
    await _push('auto_reply', next.toJson());
  }
}
