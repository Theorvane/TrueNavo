import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/dashboard/dashboard_capabilities.dart';
import 'package:truenavo/features/dashboard/deferred_observation_contracts.dart';

void main() {
  const supportedFamilies = <DashboardVersionFamily>{
    DashboardVersionFamily.v25_04,
    DashboardVersionFamily.v25_10,
    DashboardVersionFamily.v26Plus,
  };

  test('selects fixture-only contracts for every deferred domain', () {
    for (final family in supportedFamilies) {
      for (final domain in DeferredObservationDomain.values) {
        final contract = DeferredObservationContract.select(
          versionFamily: family,
          domain: domain,
        );

        expect(contract.state, DeferredObservationContractState.fixtureOnly);
        expect(contract.isRuntimeEnabled, isFalse);
        expect(contract.fixtureId, isNotEmpty);
        expect(
          contract.parseFixture(_readFixture('${contract.fixtureId!}.json')),
          isA<DeferredObservationFixture>(),
        );
      }
    }
  });

  test('represents unavailable policy and unknown version explicitly', () {
    final policyUnavailable = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.v25_10,
      domain: DeferredObservationDomain.disks,
      fixturePolicyAvailable: false,
    );
    final unknown = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.unknownUnsupported,
      domain: DeferredObservationDomain.apps,
    );

    expect(
      policyUnavailable.state,
      DeferredObservationContractState.policyUnavailable,
    );
    expect(unknown.state, DeferredObservationContractState.unknownVersion);
    expect(unknown.isRuntimeEnabled, isFalse);
  });

  test('advertised deferred methods cannot enable runtime support', () {
    final capabilities = DashboardCapabilities.forSession(
      version: 'TrueNAS-SCALE-26.0',
      availableMethodNames: const {
        'vdev.query',
        'disk.query',
        'snapshot.query',
        'app.query',
      },
    );
    final contract = DeferredObservationContract.select(
      versionFamily: capabilities.versionFamily,
      domain: DeferredObservationDomain.vdevs,
    );

    expect(capabilities.supports(DashboardFeature.vdevs), isFalse);
    expect(capabilities.supports(DashboardFeature.disks), isFalse);
    expect(capabilities.supports(DashboardFeature.snapshots), isFalse);
    expect(capabilities.supports(DashboardFeature.apps), isFalse);
    expect(contract.isRuntimeEnabled, isFalse);
  });

  test('parses fixture observations into bounded safe display fields', () {
    final fixture = _readFixture('v25_10_vdevs.json');
    final contract = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.v25_10,
      domain: DeferredObservationDomain.vdevs,
    );

    final observations = contract.parseFixture(fixture).observations;

    expect(observations, hasLength(2));
    expect(observations.first.label, 'tank / mirror-0');
    expect(observations.first.status, DeferredObservationStatus.healthy);
    expect(observations.first.summary, 'Two-way mirror is online');
  });

  test('accepts an observation list at the maximum length', () {
    final contract = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.v25_04,
      domain: DeferredObservationDomain.disks,
    );
    final item = <String, String>{
      'label': 'Example disk bay 1',
      'state': 'ONLINE',
      'summary': 'Documented display-schema example',
    };
    final fixture = <String, Object>{
      'observations': List<Object>.filled(
        DeferredObservationContract.maxObservations,
        item,
      ),
    };

    final parsed = contract.parseFixture(fixture);

    expect(parsed.observations, hasLength(50));
    expect(
      parsed.observations.first.label.length,
      lessThanOrEqualTo(DeferredObservationContract.maxDisplayCharacters),
    );
    expect(
      parsed.observations.first.summary.length,
      lessThanOrEqualTo(DeferredObservationContract.maxDisplayCharacters),
    );
  });

  test('rejects an observation list over the maximum length', () {
    final contract = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.v25_04,
      domain: DeferredObservationDomain.disks,
    );
    final fixture = <String, Object>{
      'observations': List<Object>.filled(
        DeferredObservationContract.maxObservations + 1,
        <String, String>{
          'label': 'Example disk bay 1',
          'state': 'ONLINE',
          'summary': 'Documented display-schema example',
        },
      ),
    };

    expect(() => contract.parseFixture(fixture), throwsFormatException);
  });

  test('rejects an oversized root fixture object', () {
    final contract = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.v25_04,
      domain: DeferredObservationDomain.disks,
    );
    expect(
      () => contract.parseFixture(_OversizedMap(2)),
      throwsFormatException,
    );
  });

  test('rejects an oversized fixture observation object', () {
    final contract = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.v25_04,
      domain: DeferredObservationDomain.disks,
    );
    final fixture = <String, Object>{
      'observations': <Object>[_OversizedMap(4)],
    };

    expect(() => contract.parseFixture(fixture), throwsFormatException);
  });

  test('rejects secret-shaped display values', () {
    final contract = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.v25_04,
      domain: DeferredObservationDomain.disks,
    );
    final fixture = <String, Object>{
      'observations': <Object>[
        <String, String>{
          'label': 'API key: example-display-key',
          'state': 'ONLINE',
          'summary': 'Authorization: Bearer example-display-token',
        },
      ],
    };

    expect(() => contract.parseFixture(fixture), throwsFormatException);
  });

  test('rejects recognized credential syntaxes in display values', () {
    final contract = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.v25_04,
      domain: DeferredObservationDomain.disks,
    );
    final patSummaryFixture = <String, Object>{
      'observations': <Object>[
        <String, String>{
          'label': 'disk status',
          'state': 'ONLINE',
          'summary': 'ghp_abcdefghijklmnopqrstuvwxyz0123456789',
        },
      ],
    };
    final basicAuthorizationFixture = <String, Object>{
      'observations': <Object>[
        <String, String>{
          'label': 'disk status',
          'state': 'ONLINE',
          'summary': 'Authorization: Basic Zm9vOmJhcg==',
        },
      ],
    };

    expect(
      () => contract.parseFixture(patSummaryFixture),
      throwsFormatException,
    );
    expect(
      () => contract.parseFixture(basicAuthorizationFixture),
      throwsFormatException,
    );
  });

  test(
    'rejects JWT-like and AWS access-key-like values in every display field',
    () {
      final contract = DeferredObservationContract.select(
        versionFamily: DashboardVersionFamily.v25_04,
        domain: DeferredObservationDomain.disks,
      );
      const jwtLike =
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJl';
      const awsAccessKeyLike = 'AKIAIOSFODNN7EXAMPLE';

      for (final unsafeValue in <String>[jwtLike, awsAccessKeyLike]) {
        for (final field in <String>['label', 'state', 'summary']) {
          final item = <String, String>{
            'label': 'Example disk bay 1',
            'state': 'ONLINE',
            'summary': 'Documented display-schema example',
          }..[field] = unsafeValue;

          expect(
            () => contract.parseFixture(<String, Object>{
              'observations': <Object>[item],
            }),
            throwsFormatException,
            reason: 'must reject credential-shaped $field input',
          );
        }
      }
    },
  );

  test('rejects malformed and secret-shaped fixture data', () {
    final contract = DeferredObservationContract.select(
      versionFamily: DashboardVersionFamily.v26Plus,
      domain: DeferredObservationDomain.snapshots,
    );

    expect(() => contract.parseFixture(<Object>[]), throwsFormatException);
    expect(
      () => contract.parseFixture(<String, Object>{
        'observations': <Object>[
          <String, String>{'api_token': 'nope'},
        ],
      }),
      throwsFormatException,
    );
  });
}

Object _readFixture(String name) =>
    jsonDecode(File('test/fixtures/dashboard/$name').readAsStringSync());

final class _OversizedMap extends MapBase<Object?, Object?> {
  _OversizedMap(this._length);

  final int _length;

  @override
  int get length => _length;

  @override
  Iterable<Object?> get keys => throw StateError('Entries must not be read.');

  @override
  Object? operator [](Object? key) =>
      throw StateError('Entries must not be read.');

  @override
  void operator []=(Object? key, Object? value) =>
      throw StateError('Entries must not be written.');

  @override
  void clear() => throw StateError('Entries must not be cleared.');

  @override
  Object? remove(Object? key) =>
      throw StateError('Entries must not be removed.');
}
