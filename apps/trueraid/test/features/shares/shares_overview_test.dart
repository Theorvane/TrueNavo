import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/dev/smb_shares_preview.dart';
import 'package:trueraid/dev/nfs_shares_preview.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid/features/iscsi/iscsi_page.dart';
import 'package:trueraid/features/management/management_page.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nfs_shares/nfs_shares_controller.dart';
import 'package:trueraid/features/nfs_shares/nfs_shares_page.dart';
import 'package:trueraid/features/nvme/nvme_page.dart';
import 'package:trueraid/features/nvme/nvme_overview.dart';
import 'package:trueraid/features/smb_shares/smb_shares_page.dart';
import 'package:trueraid/features/shares/shares_overview.dart';
import 'package:trueraid/features/shares/shares_page.dart';
import 'package:trueraid/features/smb_shares/smb_shares_controller.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _endpoint = 'wss://nas-demo.example/api/current';
const _privateError = 'PRIVATE-SYNTHETIC-DIAGNOSTIC';

void main() {
  test('two sequential typed inventories produce exact counts and paths without writes', () async {
    final api = _Fake();
    final result = await _load(api);
    expect(api.events, ['smb:start', 'smb:end', 'nfs:start', 'nfs:end']);
    expect(api.peak, 1);
    expect(api.mutations, 0);
    expect(result.loadedSources, 2);
    expect(result.shares.length, 7);
    expect(result.enabled, 4);
    expect(result.disabled, 3);
    expect(result.paths.length, 6);
    expect(
      result.paths['/mnt/tank/archive']!.map((s) => s.protocol).toSet(),
      ShareProtocol.values.toSet(),
    );
    expect(result.shares.map((s) => s.identity).toSet().length, 7);
    expect(result.shares.where((s) => s.dataset == null), isEmpty);
    expect(result.observedAt, DateTime.utc(2026, 9, 14));
    expect(() => result.protocols.clear(), throwsUnsupportedError);
    expect(() => result.shares.clear(), throwsUnsupportedError);
    expect(() => result.paths.clear(), throwsUnsupportedError);
    expect(() => result.paths.values.first.clear(), throwsUnsupportedError);
  });
  for (final fault in ['smb', 'nfs']) {
    test(
      'failed $fault stays unavailable instead of zero and does not retry',
      () async {
        final api = _Fake()..fail = fault;
        final result = await _load(api);
        expect(result.loadedSources, 1);
        final source = result.protocols.singleWhere((s) => !s.loaded);
        expect(source.shares, isEmpty);
        expect(source.serviceState, isNull);
        expect(source.autostart, isNull);
        expect(source.unavailable, isNot(contains(_privateError)));
        expect(result.shares.length, fault == 'smb' ? 3 : 4);
        expect(api.events.where((e) => e == '$fault:start').length, 1);
      },
    );
  }
  test('unsupported protocols are not successful empty inventories', () async {
    final result = await loadSharesOverview(
      repository: _Unavailable(),
      endpoint: _endpoint,
      isCurrent: () => true,
    );
    expect(result.loadedSources, 0);
    expect(result.shares, isEmpty);
    expect(result.protocols.every((s) => s.unavailable != null), isTrue);
  });
  test('known empty inventory is distinct from unavailable', () async {
    final api = _Fake()..empty = true;
    final result = await _load(api);
    expect(result.loadedSources, 2);
    expect(result.shares, isEmpty);
    expect(result.enabled, 0);
    expect(result.disabled, 0);
  });
  for (final state in [
    'RUNNING',
    'STOPPED',
    'UNKNOWN',
    'STARTING',
    'running',
    '',
  ]) {
    test(
      'service state $state does not invent access or healthy runtime',
      () async {
        final result = await _load(_Fake()..service = state);
        final smb = result.protocols.first;
        expect(smb.serviceState, state);
        expect(smb.needsAttention(smb.shares.first), state != 'RUNNING');
        expect(smb.needsAttention(smb.shares[2]), isFalse);
        expect(smb.needsAttention(smb.shares.last), isTrue);
      },
    );
  }
  test(
    'ambiguous and missing dataset-root mappings are never guessed',
    () async {
      final result = await _load(_Fake()..ambiguous = true);
      expect(result.protocols.first.shares.first.dataset, isNull);
      expect(result.protocols.first.shares[1].dataset, isNull);
    },
  );
  test('exact path grouping does not collapse case or descendant paths', () {
    SharedPathEntry entry(String path, int id) => SharedPathEntry(
      protocol: ShareProtocol.smb,
      id: id,
      name: 'Share',
      path: path,
      enabled: true,
      readOnly: false,
    );
    final v = SharesOverview(
      endpoint: _endpoint,
      observedAt: DateTime.utc(2026),
      protocols: [
        ShareProtocolOverview(
          protocol: ShareProtocol.smb,
          shares: [
            entry('/mnt/tank/A', 1),
            entry('/mnt/tank/a', 2),
            entry('/mnt/tank/a/child', 3),
          ],
        ),
      ],
    );
    expect(v.paths.length, 3);
  });
  test('stale before read dispatches nothing', () async {
    final api = _Fake();
    await expectLater(
      loadSharesOverview(
        repository: api,
        endpoint: _endpoint,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    expect(api.events, isEmpty);
  });
  test(
    'session change during first read stops second read and publication',
    () async {
      final api = _Fake()..pause = Completer<void>();
      var current = true;
      final pending = loadSharesOverview(
        repository: api,
        endpoint: _endpoint,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      api.pause!.complete();
      await expectLater(pending, throwsStateError);
      expect(api.events, ['smb:start', 'smb:end']);
    },
  );
  test(
    'shared pending lock prevents reads until explicit invalidation',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      final lock = h.container.read(serverOperationLockProvider),
          owner = h.container.read(serverOperationLockProvider).acquire()!;
      final sub = h.container.listen(sharesOverviewProvider, (_, _) {});
      addTearDown(sub.close);
      await expectLater(
        h.container.read(sharesOverviewProvider.future),
        throwsStateError,
      );
      expect(h.api.events, isEmpty);
      lock.release(owner);
      h.container.invalidate(sharesOverviewProvider);
      expect(
        (await h.container.read(sharesOverviewProvider.future)).loadedSources,
        2,
      );
      final next = lock.acquire();
      expect(next, isNotNull);
      lock.release(next!);
    },
  );
  test('disposing pending overview prevents later reads and releases original lock', () async {
    final h = _Harness();
    h.api.pause = Completer<void>();
    final lock = h.container.read(serverOperationLockProvider);
    final pending = h.container.read(sharesOverviewProvider.future);
    final observed = expectLater(pending, throwsStateError);
    h.container.dispose();
    h.api.pause!.complete();
    await observed;
    expect(h.api.events, ['smb:start', 'smb:end']);
    final owner = lock.acquire();
    expect(owner, isNotNull);
    lock.release(owner!);
  });
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'overview $width dark=$dark supports 200 percent text and filters without changing charts',
        (tester) async {
          _size(tester, width);
          final h = _Harness();
          addTearDown(h.container.dispose);
          await _pump(tester, h, dark: dark);
          expect(
            find.byKey(const Key('shares-enablement-chart')),
            findsOneWidget,
          );
          final filter = find.byKey(const Key('shares-overview-filter'));
          await tester.ensureVisible(filter);
          await tester.enterText(filter, 'archive');
          await tester.pumpAndSettle();
          expect(find.text('2 matching shares'), findsOneWidget);
          expect(find.text('● Enabled · 4'), findsOneWidget);
          expect(h.api.mutations, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final (key, page) in [
    ('shares-open-smb', SmbSharesPage),
    ('shares-open-nfs', NfsSharesPage),
    ('shares-open-nvme', NvmePage),
    ('shares-service-controls', ManagementPage),
  ]) {
    testWidgets('$key opens native review workspace without writes', (
      tester,
    ) async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      await _pump(tester, h);
      final target = find.byKey(Key(key));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(find.byType(page), findsOneWidget);
      expect(h.api.mutations, 0);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'partial read shows unavailable safely and not fake empty state',
    (tester) async {
      final h = _Harness();
      h.api.fail = 'smb';
      addTearDown(h.container.dispose);
      await _pump(tester, h);
      expect(
        find.textContaining('Counts are unknown, not zero.'),
        findsOneWidget,
      );
      expect(find.textContaining(_privateError), findsNothing);
      expect(find.text('● Enabled · 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('separate iSCSI summary shows bounded block topology and route', (
    tester,
  ) async {
    _size(tester, 320);
    final h = _Harness(
      block: IscsiOverview.parse(
        portals: [],
        initiators: [],
        targets: [
          {'id': 1, 'name': 'target-a', 'groups': []},
        ],
        extents: [
          {'id': 2, 'name': 'disk-a', 'type': 'DISK'},
          {'id': 3, 'name': 'disk-b', 'type': 'DISK'},
        ],
        mappings: [
          {'id': 4, 'target': 1, 'extent': 2, 'lunid': 0},
          {'id': 5, 'target': 1, 'extent': 99, 'lunid': 1},
        ],
      ),
    );
    addTearDown(h.container.dispose);
    await _pump(tester, h);
    expect(find.text('1 targets · 2 extents · 2 LUN mappings'), findsOneWidget);
    expect(find.text('1 of 2 extents mapped'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('shares-iscsi-mapped-ratio')),
          )
          .value,
      0.5,
    );
    expect(find.textContaining('1 mappings refer to'), findsOneWidget);
    expect(find.text('● Enabled · 4'), findsOneWidget);
    expect(h.api.mutations, 0);
    expect(h.blockReads, 1);
    final blockFilter = find.byKey(const Key('shares-iscsi-filter'));
    await tester.ensureVisible(blockFilter);
    await tester.enterText(blockFilter, 'disk-a');
    await tester.pumpAndSettle();
    expect(find.text('1 matching targets'), findsOneWidget);
    final target = find.byKey(const Key('shares-iscsi-target-1'));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(find.text('LUN 0 · disk-a'), findsOneWidget);
    expect(find.text('LUN 1 · Extent not returned'), findsOneWidget);
    await tester.enterText(blockFilter, 'no-such-target');
    await tester.pumpAndSettle();
    expect(find.text('0 matching targets'), findsOneWidget);
    expect(find.text('● Enabled · 4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shares-overview-refresh')));
    await tester.pumpAndSettle();
    expect(h.blockReads, 2);
    expect(tester.widget<TextField>(blockFilter).controller!.text, isEmpty);
    final open = find.byKey(const Key('shares-open-iscsi'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.byType(IscsiPage), findsOneWidget);
    expect(h.api.mutations, 0);
  });
  testWidgets('unavailable iSCSI is unknown rather than zero', (tester) async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    await _pump(tester, h);
    expect(
      find.text(
        'iSCSI inventory unavailable. Its counts are unknown, not zero.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('shares-iscsi-mapped-ratio')), findsNothing);
  });
  testWidgets('separate NVMe summary charts bounded topology and refreshes', (
    tester,
  ) async {
    _size(tester, 320);
    final h = _Harness(
      nvme: NvmeOverview.parse(
        subsystems: [
          {
            'id': 1,
            'name': 'private',
            'allow_any_host': false,
            'ana': true,
            'pi_enable': true,
          },
          {
            'id': 2,
            'name': 'other',
            'allow_any_host': false,
            'ana': null,
            'pi_enable': null,
          },
        ],
        ports: [
          {
            'id': 3,
            'addr_trtype': 'TCP',
            'enabled': true,
            'pi_enable': false,
            'addr_traddr': 'private-address',
          },
        ],
        namespaces: [
          {
            'id': 4,
            'nsid': 1,
            'subsys': {'id': 1},
            'device_type': 'ZVOL',
            'enabled': true,
            'locked': false,
            'device_path': '/nvme-secret-backing',
          },
          {
            'id': 5,
            'nsid': 2,
            'subsys': {'id': 1},
            'device_type': 'ZVOL',
            'enabled': false,
            'locked': false,
          },
        ],
        portMappings: [
          {
            'id': 6,
            'port': {'id': 3},
            'subsys': {'id': 1},
          },
        ],
      ),
    );
    addTearDown(h.container.dispose);
    await _pump(tester, h);
    expect(
      find.text('2 subsystems · 1 ports · 2 namespaces · 1 port associations'),
      findsOneWidget,
    );
    expect(
      find.text('1 of 2 subsystems have a returned port association'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('shares-nvme-port-associated-ratio')),
          )
          .value,
      0.5,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('shares-nvme-namespace-enabled-ratio')),
          )
          .value,
      0.5,
    );
    expect(find.text('ANA'), findsOneWidget);
    expect(find.text('PI'), findsOneWidget);
    expect(find.text('inherit: 1'), findsOneWidget);
    expect(find.text('server default: 1'), findsOneWidget);
    expect(find.text('on: 1'), findsNWidgets(2));
    expect(find.byKey(const Key('shares-nvme-ana-donut')), findsOneWidget);
    expect(find.byKey(const Key('shares-nvme-pi-donut')), findsOneWidget);
    expect(
      find.byKey(const Key('shares-nvme-port-transport-donut')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('shares-nvme-namespace-type-donut')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('shares-nvme-port-pi-donut')), findsOneWidget);
    expect(find.text('Port PI'), findsOneWidget);
    expect(find.text('off: 1'), findsOneWidget);
    expect(find.text('TCP: 1'), findsOneWidget);
    expect(find.text('ZVOL: 2'), findsOneWidget);
    expect(find.text('FILE: 0'), findsOneWidget);
    expect(find.textContaining('private-address'), findsNothing);
    expect(find.textContaining('/nvme-secret-backing'), findsNothing);
    expect(h.nvmeReads, 1);
    await tester.tap(find.byKey(const Key('shares-overview-refresh')));
    await tester.pumpAndSettle();
    expect(h.nvmeReads, 2);
    expect(h.api.mutations, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unreturned NVMe settings stay unknown in summary', (
    tester,
  ) async {
    final h = _Harness(
      nvme: NvmeOverview.parse(
        subsystems: [
          {'id': 1, 'name': 'legacy', 'allow_any_host': false},
        ],
        ports: [],
        namespaces: [],
        portMappings: [],
      ),
    );
    addTearDown(h.container.dispose);
    await _pump(tester, h);
    expect(find.text('not returned: 1'), findsNWidgets(2));
    expect(find.text('inherit: 0'), findsOneWidget);
    expect(find.text('server default: 0'), findsNWidgets(2));
    expect(find.byKey(const Key('shares-nvme-ana-donut')), findsOneWidget);
    expect(find.byKey(const Key('shares-nvme-pi-donut')), findsOneWidget);
    expect(
      find.byKey(const Key('shares-nvme-port-transport-donut')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('shares-nvme-namespace-type-donut')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('shares-nvme-port-pi-donut')), findsOneWidget);
    expect(find.text('TCP: 0'), findsOneWidget);
    expect(find.text('ZVOL: 0'), findsOneWidget);
    expect(h.api.mutations, 0);
  });
  testWidgets('unavailable NVMe topology is unknown rather than zero', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    await _pump(tester, h);
    expect(
      find.text(
        'NVMe-oF inventory unavailable. Its counts are unknown, not zero.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('shares-nvme-port-associated-ratio')),
      findsNothing,
    );
  });
  testWidgets('block explorer caps the visible list but searches all targets', (
    tester,
  ) async {
    final h = _Harness(
      block: IscsiOverview.parse(
        portals: [],
        initiators: [],
        targets: [
          for (var id = 1; id <= 21; id++)
            {'id': id, 'name': 'target-$id', 'groups': []},
        ],
        extents: [],
        mappings: [],
      ),
    );
    addTearDown(h.container.dispose);
    await _pump(tester, h);
    expect(find.text('21 matching targets'), findsOneWidget);
    expect(find.byKey(const Key('shares-iscsi-target-21')), findsNothing);
    final filter = find.byKey(const Key('shares-iscsi-filter'));
    await tester.ensureVisible(filter);
    await tester.enterText(filter, 'target-21');
    await tester.pumpAndSettle();
    expect(find.text('1 matching targets'), findsOneWidget);
    expect(find.byKey(const Key('shares-iscsi-target-21')), findsOneWidget);
    expect(h.blockReads, 1);
    expect(h.api.mutations, 0);
  });
  for (final protocol in ['smb', 'nfs']) {
    testWidgets(
      'reopening cached $protocol workspace reads a fresh inventory after overview refresh',
      (tester) async {
        final h = _Harness();
        addTearDown(h.container.dispose);
        await _pump(tester, h);
        final open = find.byKey(Key('shares-open-$protocol'));
        await tester.ensureVisible(open);
        await tester.tap(open);
        await tester.pumpAndSettle();
        final Object? cached = protocol == 'smb'
            ? h.container.read(smbSharesInventoryProvider).asData?.value
            : h.container.read(nfsSharesInventoryProvider).asData?.value;
        expect(cached, isNotNull);
        expect(
          protocol == 'smb'
              ? (cached! as SmbShareInventory).shares
              : (cached! as NfsShareInventory).shares,
          isNotEmpty,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();

        // The overview replaces SDK inventory leases without publishing into the
        // native provider. Model a changed inventory while that cache survives.
        h.api.empty = true;
        await tester.tap(find.byKey(const Key('shares-overview-refresh')));
        await tester.pumpAndSettle();
        expect(find.text('0 matching shares'), findsOneWidget);
        final Object? stillCached = protocol == 'smb'
            ? h.container.read(smbSharesInventoryProvider).asData?.value
            : h.container.read(nfsSharesInventoryProvider).asData?.value;
        expect(identical(stillCached, cached), isTrue);
        final selectedReads = h.api.events
            .where((e) => e == '$protocol:start')
            .length;
        final other = protocol == 'smb' ? 'nfs' : 'smb';
        final otherReads = h.api.events
            .where((e) => e == '$other:start')
            .length;

        await tester.ensureVisible(open);
        await tester.tap(open);
        await tester.pumpAndSettle();
        final Object? fresh = protocol == 'smb'
            ? h.container.read(smbSharesInventoryProvider).asData?.value
            : h.container.read(nfsSharesInventoryProvider).asData?.value;
        expect(fresh, isNotNull);
        expect(identical(fresh, cached), isFalse);
        expect(
          protocol == 'smb'
              ? (fresh! as SmbShareInventory).shares
              : (fresh! as NfsShareInventory).shares,
          isEmpty,
        );
        expect(
          h.api.events.where((e) => e == '$protocol:start').length,
          selectedReads + 1,
        );
        expect(
          h.api.events.where((e) => e == '$other:start').length,
          otherReads,
        );
        expect(h.api.mutations, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('new session hides old inventory and resets search immediately', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    await _pump(tester, h);
    final filter = find.byKey(const Key('shares-overview-filter'));
    await tester.ensureVisible(filter);
    await tester.enterText(filter, 'archive');
    await tester.pumpAndSettle();
    h.api.pause = Completer<void>();
    h.current = h.session();
    h.container.invalidate(dashboardActiveSessionProvider);
    await tester.pump();
    expect(find.text('Archive'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    h.api.pause!.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('shares-overview-filter')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('7 matching shares'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<SharesOverview> _load(_Fake api) => loadSharesOverview(
  repository: api,
  endpoint: _endpoint,
  isCurrent: () => true,
  now: () => DateTime.utc(2026, 9, 14),
);

class _Unavailable implements SessionRepository {
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw StateError('No transport');
  @override
  Future<void> close() async {}
}

class _Fake extends _Unavailable
    with SmbSharesPreviewAdapter, NfsSharesPreviewAdapter {
  final events = <String>[];
  int active = 0, peak = 0, mutations = 0;
  String? fail;
  String service = 'RUNNING';
  bool empty = false, ambiguous = false;
  Completer<void>? pause;
  Future<T> _read<T>(String name, Future<T> Function() read) async {
    events.add('$name:start');
    active++;
    if (active > peak) {
      peak = active;
    }
    try {
      if (name == 'smb') {
        await pause?.future;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (fail == name) {
        throw StateError(_privateError);
      }
      return await read();
    } finally {
      active--;
      events.add('$name:end');
    }
  }

  @override
  Future<SmbShareInventory> loadSmbShares() => _read('smb', () async {
    final i = await super.loadSmbShares();
    return SmbShareInventory(
      shares: empty ? [] : i.shares,
      datasets: ambiguous
          ? [
              const SmbShareDataset(
                id: 'tank/a',
                guid: '1',
                mountpoint: '/mnt/tank/team',
              ),
              const SmbShareDataset(
                id: 'tank/b',
                guid: '2',
                mountpoint: '/mnt/tank/team',
              ),
            ]
          : i.datasets,
      serviceState: service,
      serviceEnabled: i.serviceEnabled,
    );
  });
  @override
  Future<NfsShareInventory> loadNfsShares() => _read('nfs', () async {
    final i = await super.loadNfsShares();
    return NfsShareInventory(
      shares: empty ? [] : i.shares,
      datasets: i.datasets,
      serviceState: i.serviceState,
      serviceEnabled: i.serviceEnabled,
      protocols: i.protocols,
    );
  });
  @override
  Future<SmbShareResult> executeSmbShare(
    SmbShareReview review,
    String confirmation,
  ) {
    mutations++;
    return super.executeSmbShare(review, confirmation);
  }

  @override
  Future<NfsShareResult> executeNfsShare(
    NfsShareReview review,
    String confirmation,
  ) {
    mutations++;
    return super.executeNfsShare(review, confirmation);
  }
}

class _Harness {
  _Harness({IscsiOverview? block, NvmeOverview? nvme}) {
    current = session();
    container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => current),
        if (block != null)
          iscsiOverviewProvider.overrideWith((ref) async {
            blockReads++;
            return block;
          }),
        if (nvme != null)
          nvmeOverviewProvider.overrideWith((ref) async {
            nvmeReads++;
            return nvme;
          }),
      ],
    );
  }
  final api = _Fake();
  int blockReads = 0;
  int nvmeReads = 0;
  AuthenticatedSession? current;
  late final ProviderContainer container;
  AuthenticatedSession session() => AuthenticatedSession(
    profileId: 'sample',
    repository: api,
    availableMethodNames: const {},
    version: '25.10.1',
    endpoint: _endpoint,
  );
}

void _size(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.binding.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _pump(WidgetTester tester, _Harness h, {bool dark = true}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
        home: const SharesPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
