/// The slice of the local store that the business automations need: settings and
/// cursors, never message history.
///
/// It lives in its own file so a test can depend on the interface without
/// loading `local_store.dart` — and with it Hive, the keystore-backed
/// encryption key and `path_provider`. Same reason `NetworkWatcher` exists for
/// connectivity: the smallest seam that makes the caller testable.
abstract class MetaStore {
  T? readMeta<T>(String key);
  Map<String, dynamic>? readMetaMap(String key);
  Future<void> writeMeta(String key, Object? value);
}
