import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'rest_client.dart';

/// ---------------------------------------------------------------------------
/// Endpoint racing - the reason "Wi-Fi and mobile data" just works.
///
/// The app keeps a small list of addresses that all point at the same private
/// server:
///
///   1. `http://192.168.1.40:8787`  - LAN, only answers while you are home
///   2. `http://100.x.y.z:8787`     - Tailscale / WireGuard address
///   3. `https://chat.example.com`  - public VPS or port-forwarded router
///
/// Whenever the OS reports a network change (Wi-Fi <-> cellular), every
/// candidate is probed in parallel, and the fastest reachable one wins. If the
/// socket later drops, the same race runs again. The user never picks a server
/// after onboarding, and no request is ever retried against a dead address.
/// ---------------------------------------------------------------------------

typedef EndpointLoader = Future<List<ServerEndpoint>> Function();
typedef EndpointPersister = Future<void> Function(ServerEndpoint endpoint);

class ConnectionManager {
  ConnectionManager({
    required this.loadCandidates,
    required this.persistChoice,
    Connectivity? connectivity,
    this.probeTimeout = const Duration(seconds: 3),
    this.cacheFor = const Duration(seconds: 30),
  }) : _connectivity = connectivity ?? Connectivity();

  final EndpointLoader loadCandidates;
  final EndpointPersister persistChoice;
  final Connectivity _connectivity;
  final Duration probeTimeout;
  final Duration cacheFor;

  final ValueNotifier<ConnectionInfo> info =
      ValueNotifier(const ConnectionInfo(status: ConnectionStatus.offline));

  final StreamController<ServerEndpoint> _endpointChanges = StreamController.broadcast();
  final StreamController<List<ConnectivityResult>> _networkChanges = StreamController.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _networkSub;
  Timer? _watchdog;
  ServerEndpoint? _current;
  DateTime? _verifiedAt;
  List<ConnectivityResult> _network = const [ConnectivityResult.none];
  bool _disposed = false;

  /// Emits whenever the winning endpoint changes, so the socket can move.
  Stream<ServerEndpoint> get endpointChanges => _endpointChanges.stream;

  /// Emits on every OS-level network change (used by the UI banner).
  Stream<List<ConnectivityResult>> get networkChanges => _networkChanges.stream;

  ServerEndpoint? get current => _current;
  bool get isOnMobileData => _network.contains(ConnectivityResult.mobile) && _network.length == 1;

  Future<void> start() async {
    if (_networkSub != null) return; // idempotent
    _network = await _connectivity.checkConnectivity();
    _networkSub = _connectivity.onConnectivityChanged.listen((result) async {
      final changed = !listEquals(result, _network);
      _network = result;
      _networkChanges.add(result);
      if (changed) await reRace(reason: 'network changed');
    });

    _watchdog = Timer.periodic(const Duration(seconds: 45), (_) async {
      if (_current == null) {
        await reRace(reason: 'watchdog');
      } else {
        // Cheap liveness check keeps the badge honest between reconnects.
        final probed = await _probe(_current!);
        if (probed == null) {
          await reportFailure(_current!, reason: 'health check failed');
        } else {
          info.value = ConnectionInfo(
            status: ConnectionStatus.online,
            endpoint: _current,
            rttMs: probed.rtt,
            peerOnline: info.value.peerOnline,
          );
        }
      }
    });
  }

  /// Returns a reachable endpoint, probing only when the cache is stale.
  Future<ServerEndpoint?> ensureEndpoint({bool force = false}) async {
    final cached = _current;
    if (!force && cached != null && _verifiedAt != null) {
      if (DateTime.now().difference(_verifiedAt!) < cacheFor) return cached;
    }
    return reRace(reason: force ? 'forced' : 'stale');
  }

  /// Probes every candidate concurrently and promotes the best one.
  Future<ServerEndpoint?> reRace({String reason = 'race'}) async {
    if (_disposed) return null;
    info.value = ConnectionInfo(
      status: ConnectionStatus.probing,
      endpoint: _current,
      peerOnline: info.value.peerOnline,
    );

    final candidates = await loadCandidates();
    if (candidates.isEmpty) {
      info.value = const ConnectionInfo(status: ConnectionStatus.offline);
      return null;
    }

    final results = await Future.wait(candidates.map(_probe));
    final winners = results.whereType<_ProbeResult>().toList()
      ..sort((a, b) {
        final byKind = _kindWeight(a.endpoint.kind).compareTo(_kindWeight(b.endpoint.kind));
        return byKind != 0 ? byKind : a.rtt.compareTo(b.rtt);
      });

    if (winners.isEmpty) {
      _current = null;
      _verifiedAt = null;
      info.value = ConnectionInfo(
        status: ConnectionStatus.offline,
        lastError: 'No server reachable ($reason)',
        peerOnline: false,
      );
      return null;
    }

    final winner = winners.first;
    final changed = _current?.url != winner.endpoint.url;
    _current = winner.endpoint;
    _verifiedAt = DateTime.now();

    info.value = ConnectionInfo(
      status: ConnectionStatus.online,
      endpoint: winner.endpoint,
      rttMs: winner.rtt,
      peerOnline: info.value.peerOnline,
    );

    if (changed) {
      await persistChoice(winner.endpoint);
      if (!_endpointChanges.isClosed) _endpointChanges.add(winner.endpoint);
    }
    return winner.endpoint;
  }

  /// Called by the socket when a connection attempt or ping fails.
  Future<void> reportFailure(ServerEndpoint endpoint, {String reason = 'socket error'}) async {
    if (_current?.url == endpoint.url) {
      _current = null;
      _verifiedAt = null;
    }
    info.value = ConnectionInfo(
      status: ConnectionStatus.offline,
      endpoint: info.value.endpoint,
      lastError: reason,
      peerOnline: false,
    );
    await reRace(reason: reason);
  }

  /// Called by the socket once it is authenticated and receiving pings.
  void reportOnline({int? rttMs, bool? peerOnline}) {
    info.value = ConnectionInfo(
      status: ConnectionStatus.online,
      endpoint: _current,
      rttMs: rttMs ?? info.value.rttMs,
      peerOnline: peerOnline ?? info.value.peerOnline,
    );
  }

  /// Switches to the next-best candidate that is not [excluded].
  Future<ServerEndpoint?> advancePast(ServerEndpoint excluded) async {
    final candidates = (await loadCandidates()).where((e) => e.url != excluded.url).toList();
    if (candidates.isEmpty) return null;
    final results = await Future.wait(candidates.map(_probe));
    final winners = results.whereType<_ProbeResult>().toList()
      ..sort((a, b) => a.rtt.compareTo(b.rtt));
    if (winners.isEmpty) return null;
    _current = winners.first.endpoint;
    _verifiedAt = DateTime.now();
    if (!_endpointChanges.isClosed) _endpointChanges.add(winners.first.endpoint);
    return _current;
  }

  Future<_ProbeResult?> _probe(ServerEndpoint endpoint) async {
    final stopwatch = Stopwatch()..start();
    try {
      await ApiClient.health(endpoint.httpBase).timeout(probeTimeout);
      stopwatch.stop();
      return _ProbeResult(endpoint, stopwatch.elapsedMilliseconds);
    } catch (_) {
      return null;
    }
  }

  static int _kindWeight(EndpointKind kind) => switch (kind) {
        EndpointKind.loopback => 0,
        EndpointKind.lan => 1,
        EndpointKind.tailnet => 2,
        EndpointKind.public => 3,
      };

  Future<void> dispose() async {
    _disposed = true;
    _watchdog?.cancel();
    await _networkSub?.cancel();
    await _endpointChanges.close();
    await _networkChanges.close();
    info.dispose();
  }
}

class _ProbeResult {
  const _ProbeResult(this.endpoint, this.rtt);
  final ServerEndpoint endpoint;
  final int rtt;
}
