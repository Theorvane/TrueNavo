part of 'true_nas_session_repository.dart';

/// Dedicated interface transaction capability. Generic administration cannot
/// invoke interface writes or acknowledge a rollback timer.
abstract interface class AuthenticatedNetworkSession {
  NetworkCapabilities get networkCapabilities;
  Future<NetworkInventory> loadNetworkInventory();
  Future<NetworkChangeResult> beginNetworkTest(NetworkChangeRequest request);
  Future<NetworkChangeResult> checkNetworkTest(NetworkTransaction transaction);
  Future<NetworkChangeResult> keepNetworkTest(NetworkTransaction transaction);
  Future<NetworkChangeResult> revertNetworkTest(NetworkTransaction transaction);
}

final class NetworkCapabilities {
  const NetworkCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
  });
  const NetworkCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false;
  final bool connected;
  final bool versionSupported;
  final bool available;
  bool get supported => connected && versionSupported && available;
  String? get blockedReason => !connected
      ? 'Connect to a TrueNAS server first.'
      : !versionSupported
      ? 'Native network changes require a stable TrueNAS 25.10 release.'
      : !available
      ? 'This account does not expose all required network safety methods.'
      : null;
}

final class NetworkAddress {
  const NetworkAddress({
    this.type = 'INET',
    required this.address,
    required this.netmask,
  });
  final String type;
  final String address;
  final int netmask;
  Map<String, Object?> get _wire => {
    'type': type,
    'address': address,
    'netmask': netmask,
  };
}

final class NetworkInterfaceSnapshot {
  NetworkInterfaceSnapshot({
    required this.id,
    required this.name,
    required this.type,
    required this.description,
    required this.dhcp,
    required this.ipv6Auto,
    required this.mtu,
    required List<NetworkAddress> aliases,
    this.blockedReason,
  }) : aliases = List.unmodifiable(aliases);
  final String id;
  final String name;
  final String type;
  final String description;
  final bool dhcp;
  final bool ipv6Auto;
  final int? mtu;
  final List<NetworkAddress> aliases;
  final String? blockedReason;
  bool get editable => blockedReason == null;
}

final class NetworkInventory {
  NetworkInventory({
    required List<NetworkInterfaceSnapshot> interfaces,
    required this.failoverLicensed,
    required this.hasPendingChanges,
    required this.checkinWaitingSeconds,
    this.blockedReason,
  }) : interfaces = List.unmodifiable(interfaces);
  final List<NetworkInterfaceSnapshot> interfaces;
  final bool failoverLicensed;
  final bool hasPendingChanges;
  final int? checkinWaitingSeconds;
  final String? blockedReason;
}

final class NetworkChangeRequest {
  NetworkChangeRequest({
    required this.inventory,
    required this.interfaceId,
    required this.description,
    required this.dhcp,
    required List<NetworkAddress> ipv4Aliases,
    required this.mtu,
  }) : ipv4Aliases = List.unmodifiable(ipv4Aliases);
  final NetworkInventory inventory;
  final String interfaceId;
  final String description;
  final bool dhcp;
  final List<NetworkAddress> ipv4Aliases;
  final int? mtu;
  String? get validationError {
    if (!_networkSafeText(interfaceId, 64) ||
        interfaceId.isEmpty ||
        !_networkSafeText(description, 64)) {
      return 'Use an interface ID and description without control characters (maximum 64 characters).';
    }
    if (mtu != null && (mtu! < 1280 || mtu! > 9000)) {
      return 'MTU must be automatic or between 1280 and 9000.';
    }
    if (ipv4Aliases.length > 8 ||
        (dhcp && ipv4Aliases.isNotEmpty) ||
        (!dhcp && ipv4Aliases.isEmpty)) {
      return 'Choose DHCP without static aliases, or one to eight static IPv4 addresses.';
    }
    final seen = <String>{};
    for (final alias in ipv4Aliases) {
      if (alias.type != 'INET' ||
          !_networkIPv4(alias.address) ||
          alias.netmask < 1 ||
          alias.netmask > 32 ||
          !seen.add(alias.address)) {
        return 'Enter unique unicast IPv4 addresses with prefix lengths from 1 to 32.';
      }
    }
    return null;
  }

  Map<String, Object?> get _wire => {
    'description': description,
    'ipv4_dhcp': dhcp,
    'aliases': ipv4Aliases.map((a) => a._wire).toList(),
    'mtu': mtu,
  };
}

/// Public construction supports test fixtures, but the wire implementation only
/// accepts the exact handle it issued on its current authenticated connection.
final class NetworkTransaction {
  const NetworkTransaction({
    required this.interfaceId,
    required this.original,
    required this.requested,
  });
  final String interfaceId;
  final NetworkInterfaceSnapshot original;
  final NetworkChangeRequest requested;
}

enum NetworkChangePhase { testing, kept, reverted, rejected, unknown }

final class NetworkChangeResult {
  const NetworkChangeResult({
    required this.phase,
    this.transaction,
    this.secondsRemaining,
  });
  final NetworkChangePhase phase;
  final NetworkTransaction? transaction;
  final int? secondsRemaining;
  String get userMessage => switch (phase) {
    NetworkChangePhase.testing => 'The server is testing the change with automatic rollback. Verify connectivity before keeping it.',
    NetworkChangePhase.kept =>
      'The server confirmed the new configuration and cleared pending changes.',
    NetworkChangePhase.reverted => 'The server confirmed the original configuration and cleared pending changes.',
    NetworkChangePhase.rejected =>
      'The change was not submitted. Reload the current configuration.',
    NetworkChangePhase.unknown => 'The outcome is unconfirmed. Do not repeat the change. Check server status or use its console; rollback may not have been armed.',
  };
}

enum NetworkExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  invalidInput,
  staleSession,
  busy,
  staleInventory,
  foreignPendingChanges,
  unsupportedInterface,
}

final class NetworkException implements Exception {
  const NetworkException(this.reason);
  final NetworkExceptionReason reason;
  String get userMessage => switch (reason) {
    NetworkExceptionReason.notAuthenticated =>
      'Connect to a TrueNAS server first.',
    NetworkExceptionReason.unsupportedVersion =>
      'Native network changes require a stable TrueNAS 25.10 release.',
    NetworkExceptionReason.unavailableMethod =>
      'The required network safety methods are unavailable for this account.',
    NetworkExceptionReason.invalidInput =>
      'The network values are invalid or could not be read safely.',
    NetworkExceptionReason.staleSession => 'The connection changed. This transaction cannot be controlled from a different session.',
    NetworkExceptionReason.busy =>
      'Another server operation or network transaction is still in progress.',
    NetworkExceptionReason.staleInventory =>
      'Network configuration changed. Reload and review it again.',
    NetworkExceptionReason.foreignPendingChanges => 'The server already has pending network changes or a rollback timer. Resolve them in the original client.',
    NetworkExceptionReason.unsupportedInterface => 'This interface needs a specialized topology, IPv6, application-listener, or HA workflow.',
  };
  @override
  String toString() => userMessage;
}

final class _SessionNetwork {
  _SessionNetwork({
    required this.client,
    required ServerSummary summary,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherBusy,
    required this.requestTimeout,
  }) : versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       methods = Set.unmodifiable(summary.availableMethodNames);
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent;
  final bool Function() isOtherBusy;
  final Duration requestTimeout;
  final bool versionSupported;
  final Set<String> methods;
  final _inventories = Expando<_NetworkObservation>();
  final _submitted = Expando<bool>();
  bool isBusy = false;
  bool _calling = false;
  bool _commitAttempted = false;
  bool _keepAttempted = false;
  bool _keepAcknowledged = false;
  bool _revertAttempted = false;
  NetworkTransaction? _active;
  _NetworkObservation? _original;
  List<Map<String, Object?>>? _expected;
  NetworkChangeResult? _terminal;
  Stopwatch? _testClock;

  static const _requiredMethods = {
    'interface.query',
    'interface.update',
    'interface.commit',
    'interface.checkin',
    'interface.checkin_waiting',
    'interface.has_pending_changes',
    'interface.rollback',
    'network.configuration.config',
    'interface.network_config_to_be_removed',
    'interface.services_restarted_on_sync',
    'app.used_host_ips',
  };
  bool get _methodsAvailable =>
      methods.containsAll(_requiredMethods) &&
      (methods.contains('failover.licensed') ||
          methods.contains('system.product_type'));

  NetworkCapabilities get capabilities => NetworkCapabilities(
    connected: isCurrent(),
    versionSupported: versionSupported,
    available: _methodsAvailable,
  );

  void _guard() {
    if (!isCurrent()) {
      throw const NetworkException(NetworkExceptionReason.staleSession);
    }
    if (!versionSupported) {
      throw const NetworkException(NetworkExceptionReason.unsupportedVersion);
    }
    if (!_methodsAvailable) {
      throw const NetworkException(NetworkExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, [List<Object?> args = const []]) async {
    _guard();
    final value = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    _guard();
    return value;
  }

  Future<bool> _observeHaLicense() async {
    if (methods.contains('failover.licensed')) {
      final licensed = await _call('failover.licensed');
      if (licensed is! bool) {
        throw const NetworkException(NetworkExceptionReason.invalidInput);
      }
      return licensed;
    }
    // TS-25.10.1 system/product.py classifies all HA-capable hardware as
    // ENTERPRISE before examining licensing. COMMUNITY_EDITION therefore
    // proves standalone hardware when the direct HA read is not advertised.
    // Recheck on every observation; never fall back after a direct read fails.
    final product = await _call('system.product_type');
    if (product == 'COMMUNITY_EDITION') return false;
    throw NetworkException(
      product == 'ENTERPRISE'
          ? NetworkExceptionReason.unsupportedInterface
          : NetworkExceptionReason.invalidInput,
    );
  }

  Future<_NetworkObservation> _observe() async {
    final licensed = await _observeHaLicense();
    final pending = await _call('interface.has_pending_changes');
    final waiting = await _call('interface.checkin_waiting');
    final rows = await _call('interface.query');
    final config = await _call('network.configuration.config');
    final removals = await _call('interface.network_config_to_be_removed');
    final services = await _call('interface.services_restarted_on_sync');
    final appIps = await _call('app.used_host_ips');
    final pendingAfter = await _call('interface.has_pending_changes');
    final waitingAfter = await _call('interface.checkin_waiting');
    if (pending is! bool ||
        pendingAfter != pending ||
        (waiting != null && waiting is! int) ||
        (waitingAfter != null && waitingAfter is! int) ||
        (waiting == null) != (waitingAfter == null) ||
        (waiting is int &&
            waitingAfter is int &&
            (waitingAfter < 0 || waitingAfter > waiting)) ||
        rows is! List ||
        rows.length > 128 ||
        config is! Map ||
        removals is! List ||
        services is! List ||
        appIps is! Map ||
        appIps.keys.any((key) => key is! String) ||
        appIps.values.any(
          (ips) => ips is! List || ips.any((ip) => ip is! String),
        )) {
      throw const NetworkException(NetworkExceptionReason.invalidInput);
    }
    final configs = <Map<String, Object?>>[];
    final identifiers = <String>{};
    for (final row in rows) {
      if (row is! Map ||
          row['id'] is! String ||
          !identifiers.add(row['id'] as String)) {
        throw const NetworkException(NetworkExceptionReason.invalidInput);
      }
      final normalized = _networkClone(row) as Map<String, Object?>;
      normalized.remove(
        'state',
      ); // Runtime counters/link/DHCP addresses are not configuration.
      _networkSortAliases(normalized);
      configs.add(normalized);
    }
    configs.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    return _NetworkObservation(
      configs: configs,
      global: (_networkClone(config) as Map<String, Object?>)..remove('state'),
      licensed: licensed,
      pending: pending,
      waiting: waitingAfter as int?,
      hasImpacts: removals.isNotEmpty || services.isNotEmpty,
      // TS-25.10.1 returns IP -> app names; generated docs describe the
      // reverse mapping. Protect both shapes without discarding either.
      appIps: {
        ...appIps.keys.cast<String>(),
        ...appIps.values.expand((ips) => (ips as List).cast<String>()),
      },
    );
  }

  Future<NetworkInventory> loadInventory() async {
    _guard();
    if (_calling || isOtherBusy()) {
      throw const NetworkException(NetworkExceptionReason.busy);
    }
    _calling = true;
    try {
      final o = await _observe();
      final inventory = o.inventory;
      _inventories[inventory] = o;
      return inventory;
    } on NetworkException {
      rethrow;
    } on Object {
      throw const NetworkException(NetworkExceptionReason.invalidInput);
    } finally {
      _calling = false;
    }
  }

  Future<NetworkChangeResult> begin(NetworkChangeRequest request) async {
    _guard();
    if (isBusy || _calling || isOtherBusy()) {
      throw const NetworkException(NetworkExceptionReason.busy);
    }
    if (request.validationError != null) {
      throw const NetworkException(NetworkExceptionReason.invalidInput);
    }
    final original = _inventories[request.inventory];
    if (original == null || _submitted[request] == true) {
      throw const NetworkException(NetworkExceptionReason.staleInventory);
    }
    final candidates = request.inventory.interfaces.where(
      (i) => i.id == request.interfaceId,
    );
    if (candidates.length != 1 ||
        !candidates.single.editable ||
        original.licensed ||
        original.hasImpacts) {
      throw const NetworkException(NetworkExceptionReason.unsupportedInterface);
    }
    if (original.pending || original.waiting != null) {
      throw const NetworkException(
        NetworkExceptionReason.foreignPendingChanges,
      );
    }
    if (_networkEqual(
          candidates.single.aliases.map((a) => a._wire).toList(),
          request.ipv4Aliases.map((a) => a._wire).toList(),
        ) &&
        candidates.single.dhcp == request.dhcp &&
        candidates.single.description == request.description &&
        candidates.single.mtu == request.mtu) {
      throw const NetworkException(NetworkExceptionReason.invalidInput);
    }
    _submitted[request] = true;
    isBusy = true;
    _calling = true;
    _terminal = null;
    _active = null;
    try {
      final fresh = await _observe();
      if (fresh.pending || fresh.waiting != null) {
        throw const NetworkException(
          NetworkExceptionReason.foreignPendingChanges,
        );
      }
      if (fresh.licensed ||
          fresh.hasImpacts ||
          !_networkEqual(original.configs, fresh.configs) ||
          !_networkEqual(original.global, fresh.global)) {
        throw const NetworkException(NetworkExceptionReason.staleInventory);
      }
      final removed = candidates.single.aliases.map((a) => a.address).toSet()
        ..removeAll(request.ipv4Aliases.map((a) => a.address));
      if (removed.any(fresh.appIps.contains)) {
        throw const NetworkException(
          NetworkExceptionReason.unsupportedInterface,
        );
      }
      _original = fresh;
      _expected = fresh.configs
          .map(
            (row) => <String, Object?>{
              ...row,
              if (row['id'] == request.interfaceId) ...request._wire,
            },
          )
          .toList();
      for (final row in _expected!) {
        _networkSortAliases(row);
      }
      _active = NetworkTransaction(
        interfaceId: request.interfaceId,
        original: candidates.single,
        requested: request,
      );
      _commitAttempted = false;
      _keepAttempted = false;
      _keepAcknowledged = false;
      _revertAttempted = false;
      await _call('interface.update', [request.interfaceId, request._wire]);
      final staged = await _observe();
      if (!_matchesExpected(staged) ||
          !staged.pending ||
          staged.waiting != null ||
          staged.hasImpacts ||
          _hasAppImpact(staged)) {
        return _unknown();
      }
      _commitAttempted = true;
      _testClock = Stopwatch()..start();
      final committed = await _call('interface.commit', [
        {'rollback': true, 'checkin_timeout': 60},
      ]);
      if (committed != null) return _unknown();
      // The server arms its timer after interface synchronization completes.
      // Start the acknowledged window here, not before that potentially slow
      // synchronization. A positive freshly-read server timer is still required.
      _testClock!.reset();
      return _classify(await _observe());
    } on Object catch (error) {
      if (_active != null) return _unknown();
      if (error is NetworkException) rethrow;
      throw const NetworkException(NetworkExceptionReason.invalidInput);
    } finally {
      _calling = false;
      if (_active == null) isBusy = false;
    }
  }

  bool _matchesExpected(_NetworkObservation o) =>
      !o.licensed &&
      _networkEqual(o.configs, _expected) &&
      _networkEqual(o.global, _original!.global);
  bool _hasAppImpact(_NetworkObservation o) {
    final retained = _active!.requested.ipv4Aliases
        .map((a) => a.address)
        .toSet();
    return _active!.original.aliases.any(
      (a) => !retained.contains(a.address) && o.appIps.contains(a.address),
    );
  }

  NetworkChangeResult _unknown() => NetworkChangeResult(
    phase: NetworkChangePhase.unknown,
    transaction: _active,
  );

  NetworkChangeResult _classify(_NetworkObservation o) {
    if (!o.licensed &&
        !o.pending &&
        o.waiting == null &&
        _networkEqual(o.global, _original!.global) &&
        _networkEqual(o.configs, _original!.configs)) {
      return _complete(NetworkChangePhase.reverted);
    }
    if (_matchesExpected(o) && !o.hasImpacts && !_hasAppImpact(o)) {
      if (!o.pending && o.waiting == null && _keepAcknowledged) {
        return _complete(NetworkChangePhase.kept);
      }
      if (o.pending &&
          o.waiting != null &&
          _liveTestWindow(o) &&
          _commitAttempted &&
          !_keepAttempted &&
          !_revertAttempted) {
        return NetworkChangeResult(
          phase: NetworkChangePhase.testing,
          transaction: _active,
          secondsRemaining: o.waiting,
        );
      }
    }
    return _unknown();
  }

  NetworkChangeResult _complete(NetworkChangePhase phase) {
    isBusy = false;
    return _terminal = NetworkChangeResult(phase: phase, transaction: _active);
  }

  bool _liveTestWindow(_NetworkObservation o) {
    final elapsed = _testClock?.elapsed.inSeconds;
    return elapsed != null &&
        elapsed < 60 &&
        o.waiting != null &&
        o.waiting! > 0 &&
        o.waiting! <= 61 - elapsed;
  }

  void _guardHandle(NetworkTransaction transaction) {
    _guard();
    if (!identical(transaction, _active)) {
      throw const NetworkException(NetworkExceptionReason.staleSession);
    }
    if (_calling) throw const NetworkException(NetworkExceptionReason.busy);
  }

  Future<NetworkChangeResult> check(NetworkTransaction transaction) async {
    _guardHandle(transaction);
    if (_terminal != null) return _terminal!;
    _calling = true;
    try {
      return _classify(await _observe());
    } on Object {
      return _unknown();
    } finally {
      _calling = false;
    }
  }

  Future<NetworkChangeResult> finish(
    NetworkTransaction transaction, {
    required bool keep,
  }) async {
    _guardHandle(transaction);
    if (_terminal != null) return _terminal!;
    if (keep ? _keepAttempted : _revertAttempted) return _unknown();
    _calling = true;
    try {
      final fresh = await _observe();
      final classified = _classify(fresh);
      if (_terminal != null) return classified;
      // Server-global transactions have no owner token. We only operate while
      // every configuration entry is still exactly the state this handle staged.
      if (!_matchesExpected(fresh) ||
          !fresh.pending ||
          (_commitAttempted && !_liveTestWindow(fresh)) ||
          (!_commitAttempted && fresh.waiting != null) ||
          (keep &&
              (!_commitAttempted ||
                  fresh.hasImpacts ||
                  _hasAppImpact(fresh)))) {
        return _unknown();
      }
      if (keep) {
        _keepAttempted = true;
      } else {
        _revertAttempted = true;
      }
      final result = await _call(
        keep ? 'interface.checkin' : 'interface.rollback',
      );
      if (result != null) return _unknown();
      if (keep) _keepAcknowledged = true;
      return _classify(await _observe());
    } on Object {
      return _unknown();
    } finally {
      _calling = false;
    }
  }
}

final class _NetworkObservation {
  _NetworkObservation({
    required this.configs,
    required this.global,
    required this.licensed,
    required this.pending,
    required this.waiting,
    required this.hasImpacts,
    required this.appIps,
  });
  final List<Map<String, Object?>> configs;
  final Map<String, Object?> global;
  final bool licensed;
  final bool pending;
  final int? waiting;
  final bool hasImpacts;
  final Set<String> appIps;
  NetworkInventory get inventory {
    final members = <String>{};
    for (final row in configs) {
      for (final key in ['bridge_members', 'lag_ports']) {
        final values = row[key];
        if (values != null && values is! List) {
          throw const NetworkException(NetworkExceptionReason.invalidInput);
        }
        if (values is List) members.addAll(values.whereType<String>());
      }
      if (row['vlan_parent_interface'] case final String parent) {
        members.add(parent);
      }
    }
    final interfaces = <NetworkInterfaceSnapshot>[];
    for (final row in configs) {
      if (row['id'] is! String ||
          row['name'] is! String ||
          row['type'] is! String ||
          row['description'] is! String ||
          row['ipv4_dhcp'] is! bool ||
          row['ipv6_auto'] is! bool ||
          row['aliases'] is! List ||
          (row['mtu'] != null && row['mtu'] is! int)) {
        throw const NetworkException(NetworkExceptionReason.invalidInput);
      }
      final aliases = <NetworkAddress>[];
      for (final a in row['aliases'] as List) {
        if (a is! Map ||
            a['type'] is! String ||
            a['address'] is! String ||
            a['netmask'] is! int) {
          throw const NetworkException(NetworkExceptionReason.invalidInput);
        }
        aliases.add(
          NetworkAddress(
            type: a['type'] as String,
            address: a['address'] as String,
            netmask: a['netmask'] as int,
          ),
        );
      }
      final supported =
          row['type'] == 'PHYSICAL' &&
          row['fake'] == false &&
          row['ipv6_auto'] == false &&
          aliases.every((a) => a.type == 'INET') &&
          !members.contains(row['id']) &&
          !members.contains(row['name']);
      interfaces.add(
        NetworkInterfaceSnapshot(
          id: row['id'] as String,
          name: row['name'] as String,
          type: row['type'] as String,
          description: row['description'] as String,
          dhcp: row['ipv4_dhcp'] as bool,
          ipv6Auto: row['ipv6_auto'] as bool,
          mtu: row['mtu'] as int?,
          aliases: aliases,
          blockedReason: supported ? null : 'Only standalone physical interfaces without configured IPv6 can be edited here.',
        ),
      );
    }
    return NetworkInventory(
      interfaces: interfaces,
      failoverLicensed: licensed,
      hasPendingChanges: pending,
      checkinWaitingSeconds: waiting,
      blockedReason: licensed
          ? 'HA network changes require a dedicated failover workflow.'
          : pending || waiting != null
          ? 'Existing network changes must be resolved by their original client.'
          : hasImpacts
          ? 'Gateway, DNS, or service listener changes require a specialized review.'
          : null,
    );
  }
}

bool _networkSafeText(String value, int max) =>
    value.length <= max &&
    !RegExp(
      r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
    ).hasMatch(value);
bool _networkIPv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4 ||
      parts.any((p) => !RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(p))) {
    return false;
  }
  final octets = parts.map(int.parse).toList();
  return octets.every((v) => v <= 255) &&
      octets.first > 0 &&
      octets.first < 224 &&
      octets.first != 127 &&
      !(octets[0] == 169 && octets[1] == 254);
}

Object? _networkClone(Object? value, [int depth = 0]) {
  if (depth > 12) {
    throw const NetworkException(NetworkExceptionReason.invalidInput);
  }
  if (value == null || value is bool || value is num) return value;
  if (value is String && _networkSafeText(value, 4096)) return value;
  if (value is List && value.length <= 256) {
    return value.map((v) => _networkClone(v, depth + 1)).toList();
  }
  if (value is Map &&
      value.length <= 256 &&
      value.keys.every((k) => k is String && _networkSafeText(k, 128))) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key as String: _networkClone(entry.value, depth + 1),
    };
  }
  throw const NetworkException(NetworkExceptionReason.invalidInput);
}

bool _networkEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _networkEqual(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(
          a.length,
          (i) => i,
        ).every((i) => _networkEqual(a[i], b[i]));
  }
  return a == b;
}

void _networkSortAliases(Map<String, Object?> row) {
  final aliases = row['aliases'];
  if (aliases is List && aliases.every((a) => a is Map)) {
    aliases.sort(
      (a, b) => '${a['type']}/${a['address']}/${a['netmask']}'.compareTo(
        '${b['type']}/${b['address']}/${b['netmask']}',
      ),
    );
  }
}
