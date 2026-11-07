import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:friend_chat/data/connection_manager.dart';
import 'package:friend_chat/models/models.dart';

/// Stands in for `GET /api/health`: records every probe and fails for hosts that
/// are not in [latencies].
class _FakeProber {
  _FakeProber(this.latencies);

  final Map<String, Duration> latencies;
  final List<String> calls = [];

  Future<void> call(String httpBase) async {
    calls.add(httpBase);
    final delay = latencies[httpBase];
    if (delay == null) throw StateError('unreachable: $httpBase');
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }

  int callsTo(String httpBase) => calls.where((c) => c == httpBase).length;
}

/// Stands in for the OS network: [check] answers once at startup, and [emit]
/// plays the part of the platform's change stream.
class _FakeNetwork implements NetworkWatcher {
  _FakeNetwork(this.current);

  List<ConnectivityResult> current;
  int checks = 0;
  final StreamController<List<ConnectivityResult>> _controller = StreamController.broadcast();

  @override
  Future<List<ConnectivityResult>> check() async {
    checks++;
    return current;
  }

  @override
  Stream<List<ConnectivityResult>> get changes => _controller.stream;

  void emit(List<ConnectivityResult> value) {
    current = value;
    _controller.add(value);
  }

  Future<void> close() => _controller.close();
}

/// Waits for [condition] without assuming an exact tick count, so the watchdog
/// tests stay stable on a slow machine.
Future<void> _waitUntil(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition never became true within ${timeout.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

ServerEndpoint _endpoint(String host, EndpointKind kind) =>
    ServerEndpoint(url: 'http://$host:8787', kind: kind);

final _lan = _endpoint('192.168.1.40', EndpointKind.lan);
final _tailnet = _endpoint('100.64.0.7', EndpointKind.tailnet);
final _public = _endpoint('chat.example.com', EndpointKind.public);

/// Builds a manager whose candidate list and persistence are observable.
({ConnectionManager manager, List<ServerEndpoint> persisted, List<ServerEndpoint> emitted})
    _manager(
  _FakeProber prober, {
  List<ServerEndpoint>? candidates,
  _FakeNetwork? network,
  Duration? watchdogInterval,
}) {
  final persisted = <ServerEndpoint>[];
  final emitted = <ServerEndpoint>[];
  var current = candidates ?? [_lan, _tailnet, _public];
  final manager = ConnectionManager(
    loadCandidates: () async => current,
    persistChoice: (endpoint) async => persisted.add(endpoint),
    prober: prober.call,
    network: network,
    watchdogInterval: watchdogInterval ?? const Duration(seconds: 45),
  );
  return (manager: manager, persisted: persisted, emitted: emitted);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('prefers the LAN address even when the public one answers faster', () async {
    final prober = _FakeProber({
      _lan.httpBase: const Duration(milliseconds: 30),
      _public.httpBase: const Duration(milliseconds: 1),
    });
    final harness = _manager(prober);
    final manager = harness.manager;

    final winner = await manager.reRace();

    expect(winner?.url, _lan.url);
    expect(manager.info.value.status, ConnectionStatus.online);
    expect(manager.info.value.endpoint?.url, _lan.url);
    expect(harness.persisted.single.url, _lan.url);
    await manager.dispose();
  });

  test('within one kind the lowest RTT wins', () async {
    final slowTailnet = _endpoint('100.64.0.9', EndpointKind.tailnet);
    final prober = _FakeProber({
      _tailnet.httpBase: const Duration(milliseconds: 25),
      slowTailnet.httpBase: const Duration(milliseconds: 2),
    });
    final manager = _manager(prober, candidates: [_tailnet, slowTailnet]).manager;

    final winner = await manager.reRace();

    expect(winner?.url, slowTailnet.url);
    expect(manager.info.value.rttMs, isNotNull);
    await manager.dispose();
  });

  test('every probe is raced in parallel, not sequentially', () async {
    const delay = Duration(milliseconds: 200);
    final prober = _FakeProber({
      _lan.httpBase: delay,
      _tailnet.httpBase: delay,
      _public.httpBase: delay,
    });
    final manager = _manager(prober).manager;

    final stopwatch = Stopwatch()..start();
    await manager.reRace();
    stopwatch.stop();

    expect(prober.calls, hasLength(3));
    // Sequential probes would take 600 ms; the budget below proves parallelism
    // without depending on exact timing.
    expect(stopwatch.elapsedMilliseconds, lessThan(550));
    await manager.dispose();
  });

  test('no reachable candidate reports offline and clears the endpoint', () async {
    final prober = _FakeProber({});
    final manager = _manager(prober).manager;

    final winner = await manager.reRace(reason: 'test');

    expect(winner, isNull);
    expect(manager.current, isNull);
    expect(manager.info.value.status, ConnectionStatus.offline);
    expect(manager.info.value.lastError, contains('No server reachable'));
    expect(manager.info.value.peerOnline, isFalse);
    await manager.dispose();
  });

  test('an empty candidate list is offline, not an error', () async {
    final manager = _manager(_FakeProber({}), candidates: []).manager;

    expect(await manager.reRace(), isNull);
    expect(manager.info.value.status, ConnectionStatus.offline);
    await manager.dispose();
  });

  test('ensureEndpoint reuses the winner while the cache is fresh', () async {
    final prober = _FakeProber({_lan.httpBase: Duration.zero});
    final manager = _manager(prober, candidates: [_lan]).manager;

    await manager.ensureEndpoint();
    await manager.ensureEndpoint();
    expect(prober.calls, hasLength(1));

    await manager.ensureEndpoint(force: true);
    expect(prober.calls, hasLength(2));
    await manager.dispose();
  });

  test('does not re-persist an unchanged winner but does emit changes once', () async {
    final prober = _FakeProber({_lan.httpBase: Duration.zero});
    final harness = _manager(prober, candidates: [_lan]);
    final manager = harness.manager;
    final emitted = <ServerEndpoint>[];
    manager.endpointChanges.listen(emitted.add);

    await manager.reRace();
    await manager.reRace();
    await Future<void>.delayed(Duration.zero);

    expect(harness.persisted, hasLength(1));
    expect(emitted.map((e) => e.url), [_lan.url]);
    await manager.dispose();
  });

  test('a failed health check demotes the endpoint and re-races', () async {
    final prober = _FakeProber({
      _lan.httpBase: Duration.zero,
      _public.httpBase: const Duration(milliseconds: 1),
    });
    final manager = _manager(prober).manager;

    expect((await manager.reRace())?.url, _lan.url);

    // The LAN address stops answering (left home).
    prober.latencies.remove(_lan.httpBase);
    await manager.reportFailure(_lan, reason: 'socket error');

    expect(manager.current?.url, _public.url);
    expect(manager.info.value.status, ConnectionStatus.online);
    await manager.dispose();
  });

  test('advancePast skips the endpoint that just failed', () async {
    final prober = _FakeProber({
      _lan.httpBase: const Duration(milliseconds: 2),
      _public.httpBase: const Duration(milliseconds: 1),
    });
    final manager = _manager(prober).manager;

    final next = await manager.advancePast(_lan);

    expect(next?.url, _public.url);
    await manager.dispose();
  });

  test('advancePast returns null when nothing else is reachable', () async {
    final prober = _FakeProber({_lan.httpBase: Duration.zero});
    final manager = _manager(prober, candidates: [_lan]).manager;

    expect(await manager.advancePast(_lan), isNull);
    await manager.dispose();
  });

  test('reportOnline keeps the chosen endpoint and merges peer state', () async {
    final prober = _FakeProber({_lan.httpBase: Duration.zero});
    final manager = _manager(prober, candidates: [_lan]).manager;
    await manager.reRace();

    manager.reportOnline(rttMs: 12, peerOnline: true);

    expect(manager.info.value.status, ConnectionStatus.online);
    expect(manager.info.value.endpoint?.url, _lan.url);
    expect(manager.info.value.rttMs, 12);
    expect(manager.info.value.peerOnline, isTrue);
    await manager.dispose();
  });

  test('endpoint helpers normalise http/ws bases', () {
    expect(_endpoint('192.168.1.40', EndpointKind.lan).httpBase, 'http://192.168.1.40:8787');
    const secure = ServerEndpoint(url: 'wss://chat.example.com', kind: EndpointKind.public);
    expect(secure.httpBase, 'https://chat.example.com');
    expect(secure.socketBase, 'wss://chat.example.com');
    expect(secure.isSecure, isTrue);
    expect(_lan.isLocal, isTrue);
    expect(_public.isLocal, isFalse);
  });

  group('network changes', () {
    test('start() is idempotent and records the current transport', () async {
      final network = _FakeNetwork([ConnectivityResult.wifi]);
      final prober = _FakeProber({_lan.httpBase: Duration.zero});
      final manager = _manager(prober, candidates: [_lan], network: network).manager;

      await manager.start();
      await manager.start();

      expect(network.checks, 1, reason: 'a second start() must not re-subscribe');
      expect(manager.isOnMobileData, isFalse);

      await manager.dispose();
      await network.close();
    });

    test('isOnMobileData is true only when cellular is the sole transport', () async {
      final network = _FakeNetwork([ConnectivityResult.mobile]);
      final prober = _FakeProber({});
      final manager = _manager(prober, network: network).manager;
      await manager.start();

      expect(manager.isOnMobileData, isTrue);

      network.emit([ConnectivityResult.mobile, ConnectivityResult.wifi]);
      await pumpEventQueue();
      expect(manager.isOnMobileData, isFalse, reason: 'Wi-Fi alongside cellular is not mobile data');

      network.emit([ConnectivityResult.none]);
      await pumpEventQueue();
      expect(manager.isOnMobileData, isFalse);

      await manager.dispose();
      await network.close();
    });

    test('a network change is published to the UI and re-races the endpoints', () async {
      final network = _FakeNetwork([ConnectivityResult.wifi]);
      final prober = _FakeProber({_lan.httpBase: Duration.zero});
      final manager = _manager(prober, candidates: [_lan], network: network).manager;
      final seen = <List<ConnectivityResult>>[];
      manager.networkChanges.listen(seen.add);

      await manager.start();
      expect(prober.calls, isEmpty, reason: 'start() alone does not probe');

      network.emit([ConnectivityResult.mobile]);
      await pumpEventQueue();

      expect(seen.last, [ConnectivityResult.mobile]);
      expect(prober.callsTo(_lan.httpBase), 1);
      expect(manager.info.value.status, ConnectionStatus.online);

      await manager.dispose();
      await network.close();
    });
  });

  // The watchdog runs on real timers here, shortened to tens of milliseconds;
  // no widget binding is involved, so nothing needs pumping.
  const tick = Duration(milliseconds: 20);

  group('watchdog', () {
    test('re-races when there is no endpoint yet', () async {
      final network = _FakeNetwork([ConnectivityResult.wifi]);
      final prober = _FakeProber({});
      final manager =
          _manager(prober, network: network, watchdogInterval: tick).manager;
      await manager.start();
      expect(manager.current, isNull);

      await _waitUntil(() => prober.calls.isNotEmpty);

      expect(manager.info.value.status, ConnectionStatus.offline,
          reason: 'the tick tried, and nothing answered');

      await manager.dispose();
      await network.close();
    });

    test('refreshes the badge while online without changing the endpoint', () async {
      final network = _FakeNetwork([ConnectivityResult.wifi]);
      final prober = _FakeProber({_lan.httpBase: Duration.zero});
      final manager =
          _manager(prober, candidates: [_lan], network: network, watchdogInterval: tick)
              .manager;
      await manager.start();
      await manager.reRace();
      manager.reportOnline(rttMs: 99, peerOnline: true);
      final probesBeforeTick = prober.callsTo(_lan.httpBase);

      await _waitUntil(() => prober.callsTo(_lan.httpBase) > probesBeforeTick);

      expect(manager.current?.url, _lan.url);
      expect(manager.info.value.status, ConnectionStatus.online);
      expect(manager.info.value.rttMs, isNot(99), reason: 'the tick replaces the stale RTT');
      expect(manager.info.value.peerOnline, isTrue,
          reason: 'peer presence must survive a health check');

      await manager.dispose();
      await network.close();
    });

    test('demotes an endpoint whose health check fails, then moves on', () async {
      final network = _FakeNetwork([ConnectivityResult.wifi]);
      final prober = _FakeProber({
        _lan.httpBase: Duration.zero,
        _public.httpBase: Duration.zero,
      });
      final manager = _manager(prober, network: network, watchdogInterval: tick).manager;
      await manager.start();
      expect((await manager.reRace())?.url, _lan.url);

      // Left the house: the LAN address stops answering.
      prober.latencies.remove(_lan.httpBase);

      await _waitUntil(() => manager.current?.url == _public.url);

      expect(manager.info.value.status, ConnectionStatus.online);

      await manager.dispose();
      await network.close();
    });
  });

  test('PluginNetworkWatcher reads the plugin channels', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const methodChannel = MethodChannel('dev.fluttercommunity.plus/connectivity');
    const eventChannel = EventChannel('dev.fluttercommunity.plus/connectivity_status');

    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      expect(call.method, 'check');
      return ['wifi'];
    });

    final pushed = StreamController<List<String>>();
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (arguments, sink) {
        pushed.stream.listen(sink.success, onDone: sink.endOfStream);
      }),
    );

    final watcher = PluginNetworkWatcher();

    expect(await watcher.check(), [ConnectivityResult.wifi]);

    final seen = <List<ConnectivityResult>>[];
    final subscription = watcher.changes.listen(seen.add);
    pushed.add(['mobile']);
    await pumpEventQueue();

    expect(seen, [
      [ConnectivityResult.mobile]
    ]);

    await subscription.cancel();
    await pushed.close();
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  test('reportOnline with no arguments keeps the previous rtt and peer state', () async {
    final prober = _FakeProber({_lan.httpBase: Duration.zero});
    final manager = _manager(prober, candidates: [_lan]).manager;
    await manager.reRace();
    manager.reportOnline(rttMs: 42, peerOnline: true);

    manager.reportOnline();

    expect(manager.info.value.rttMs, 42);
    expect(manager.info.value.peerOnline, isTrue);
    expect(manager.info.value.endpoint?.url, _lan.url);
    await manager.dispose();
  });
}
