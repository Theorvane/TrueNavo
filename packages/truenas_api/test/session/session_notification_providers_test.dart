import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'notification_providers_fixtures.dart';

void main() {
  test('disconnected is incapable and never connects implicitly', () async {
    final wire = ProvidersWire(),
        repo = TrueNasSessionRepository(connector: ProvidersConnector(wire));
    addTearDown(repo.close);
    expect(repo.notificationProvidersCapabilities.supported, isFalse);
    await expectLater(
      repo.loadNotificationProviders(),
      throwsA(
        providerReason(NotificationProvidersExceptionReason.notAuthenticated),
      ),
    );
    expect(wire.calls, isEmpty);
  });
  for (final provider in NotificationProviderType.values) {
    test(
      '${provider.name} inventory never requests attributes or exposes credentials',
      () async {
        final h = await providersConnected(
          configure: (w) => w.rows = [npRow(provider)],
        );
        final i = await h.repo.loadNotificationProviders();
        expect(i.services.single.provider, provider);
        final queries = h.wire.calls
            .where((c) => c['method'] == 'alertservice.query')
            .toList();
        expect(queries, hasLength(1));
        expect(queries.single['params'][0], isEmpty);
        expect(jsonEncode(queries), isNot(contains('attributes')));
        expect('${i.services.single}', isNot(contains(npSecret)));
        expect(providerWrites(h), isEmpty);
      },
    );
    for (final action in NotificationProvidersAction.values) {
      test(
        '${provider.name}/${action.name} fixed full envelope and verified readback without provider test',
        () async {
          final h = await providersConnected(
            configure: (w) => w.rows = [
              npRow(
                provider,
                enabled: action == NotificationProvidersAction.disable,
              ),
            ],
          );
          final r = await providerReview(h, provider: provider, action: action);
          expect(providerWrites(h), isEmpty);
          expect(r.target, contains(npHost));
          expect(r.target, contains(provider.wireName));
          expect(r.destinationSummary, isNot(contains(npSecret)));
          expect(jsonEncode(r.publicFields), isNot(contains(npSecret)));
          expect(
            r.destinationSummary,
            contains('Opaque per-session destination reference'),
          );
          final result = await providerExecute(h, r);
          expect(result.outcome, NotificationProvidersOutcome.completed);
          final sent = providerWrites(h);
          expect(sent, hasLength(1));
          if (action == NotificationProvidersAction.delete) {
            expect(sent.single['params'], [1]);
          } else {
            final envelope = sent.single['params'].last as Map;
            expect(envelope.keys.toSet(), {
              'name',
              'level',
              'attributes',
              'enabled',
            });
            expect(
              envelope['enabled'],
              action == NotificationProvidersAction.enable,
            );
            expect(
              envelope['attributes'],
              npAttributes(
                provider,
                suffix:
                    action == NotificationProvidersAction.create ||
                        action == NotificationProvidersAction.replace
                    ? '_NEW'
                    : '',
              ),
            );
            if (action == NotificationProvidersAction.create ||
                action == NotificationProvidersAction.replace) {
              expect(r.request.credentials!.isDisposed, isTrue);
            }
          }
          final after = h.wire.calls.length;
          expect(
            (await providerExecute(h, r)).outcome,
            NotificationProvidersOutcome.rejected,
          );
          expect(h.wire.calls.length, after);
          expect(
            h.wire.calls.every(
              (c) => [
                ...npReads,
                ...npWrites,
                'auth.login_ex',
                'system.info',
                'core.get_methods',
              ].contains(c['method']),
            ),
            isTrue,
          );
        },
      );
    }
    test('${provider.name} dispose makes credential replacement unusable', () {
      final capsule = NotificationProviderCredentials(
        provider: provider,
        values: npCredentials(provider),
      );
      expect(capsule.validationError, isNull);
      expect('$capsule', isNot(contains(npSecret)));
      capsule.dispose();
      expect(capsule.isDisposed, isTrue);
      expect(capsule.validationError, isNotNull);
    });
  }
  for (final cause in [
    'expiry',
    'futuretime',
    'target',
    'foreground',
    'host',
    'row',
    'secret',
    'secretlate',
    'capability',
  ]) {
    test('$cause invalidates one-use reviewed write before dispatch', () async {
      final h = await providersConnected();
      final r = await providerReview(h);
      if (cause == 'expiry') {
        h.now = h.now.add(const Duration(minutes: 5, seconds: 1));
      }
      if (cause == 'futuretime') {
        h.now = h.now.subtract(const Duration(seconds: 1));
      }
      if (cause == 'foreground') h.authorized = false;
      if (cause == 'host') h.wire.values['system.host_id'] = 'f' * 64;
      if (cause == 'row') h.wire.rows.first['name'] = 'Drifted';
      if (cause == 'secret') {
        (h.wire.rows.first['attributes'] as Map)['url'] =
            'https://hooks.example.test/private/CHANGED';
      }
      if (cause == 'secretlate') {
        var reads = 0;
        h.wire.beforeReply = (method, _) {
          if (method == 'system.state' && ++reads == 4) {
            (h.wire.rows.first['attributes'] as Map)['url'] =
                'https://hooks.example.test/private/CHANGED';
          }
        };
      }
      if (cause == 'capability') h.wire.current = false;
      final result = await h.repo.executeNotificationProviders(
        r,
        cause == 'target' ? '${r.target} ' : r.target,
        isCurrent: () => h.authorized,
      );
      expect(result.outcome, NotificationProvidersOutcome.rejected);
      expect(providerWrites(h), isEmpty);
      expect(r.request.credentials!.isDisposed, isTrue);
    });
  }
  for (final kind in [
    'rpcerror',
    'throw',
    'receipt',
    'readback',
    'afterwriteforeground',
  ]) {
    test(
      '$kind after invocation is unknown and terminal without retry',
      () async {
        final h = await providersConnected();
        final r = await providerReview(h);
        if (kind == 'rpcerror') h.wire.fault = 'alertservice.update';
        if (kind == 'throw') h.wire.throwMethod = 'alertservice.update';
        if (kind == 'receipt') {
          h.wire.overrideReceipt = true;
          h.wire.receipt = false;
        }
        if (kind == 'readback') h.wire.mutate = false;
        if (kind == 'afterwriteforeground') {
          h.wire.afterWrite = () => h.authorized = false;
        }
        final result = await providerExecute(h, r);
        expect(result.outcome, NotificationProvidersOutcome.unknown);
        expect(result.message, isNot(contains(npSecret)));
        final count = h.wire.calls.length;
        await expectLater(
          h.repo.loadNotificationProviders(),
          throwsA(providerReason(NotificationProvidersExceptionReason.busy)),
        );
        expect(
          (await providerExecute(h, r)).outcome,
          NotificationProvidersOutcome.rejected,
        );
        expect(h.wire.calls.length, count);
      },
    );
  }
  test('new load and close destroy SDK-reviewed secret capsules', () async {
    final h = await providersConnected();
    final first = await providerReview(h);
    await h.repo.loadNotificationProviders();
    expect(first.request.credentials!.isDisposed, isTrue);
    final second = await providerReview(h);
    await h.repo.close();
    expect(second.request.credentials!.isDisposed, isTrue);
  });
  test('held awaited read foreground expiry cannot dispatch late', () async {
    final h = await providersConnected();
    final r = await providerReview(h);
    h.wire.hold = 'auth.me';
    h.wire.held = Completer<void>();
    final pending = providerExecute(h, r);
    await Future<void>.delayed(Duration.zero);
    h.authorized = false;
    r.request.credentials!.dispose();
    h.wire.held!.complete();
    expect((await pending).outcome, NotificationProvidersOutcome.rejected);
    expect(providerWrites(h), isEmpty);
  });
  for (final provider in [
    NotificationProviderType.slack,
    NotificationProviderType.mattermost,
    NotificationProviderType.opsGenie,
  ]) {
    test(
      '${provider.name} legacy HTTP can only stop or delete, never enable',
      () async {
        final h = await providersConnected(
          configure: (w) {
            w.rows = [npRow(provider)];
            (w.rows.first['attributes'] as Map)[provider ==
                        NotificationProviderType.opsGenie
                    ? 'api_url'
                    : 'url'] =
                'http://legacy.example.test/private/secret';
          },
        );
        await expectLater(
          providerReview(
            h,
            provider: provider,
            action: NotificationProvidersAction.enable,
          ),
          throwsA(
            providerReason(
              NotificationProvidersExceptionReason.invalidResponse,
            ),
          ),
        );
        final r = await providerReview(
          h,
          provider: provider,
          action: NotificationProvidersAction.delete,
        );
        expect(
          (await providerExecute(h, r)).outcome,
          NotificationProvidersOutcome.completed,
        );
      },
    );
  }
}
