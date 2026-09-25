import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/readonly_probe_policy.dart';

const _sentinel = 'test-secret-must-never-appear';
const _properties = [
  'guid',
  'creation',
  'used',
  'referenced',
  'available',
  'quota',
  'refquota',
  'reservation',
  'refreservation',
  'compression',
  'atime',
  'readonly',
  'mountpoint',
  'encryption',
  'encryptionroot',
  'keystatus',
  'acltype',
  'aclmode',
  'filesystem_count',
];
String _frame(String method, {Object id = 'm0-1', Object? params}) =>
    jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'id': id,
      'params': ?params,
    });
List<Object?> _history({
  String name = 'cpu',
  String? identifier,
  int start = 1720000000,
  int end = 1720000600,
}) => [
  [
    <String, Object?>{'name': name, 'identifier': identifier},
  ],
  <String, Object?>{'start': start, 'end': end, 'aggregate': true},
];
List<Object?> _dataset() => [
  [
    [
      'type',
      'in',
      ['FILESYSTEM', 'VOLUME'],
    ],
  ],
  {
    'limit': 1025,
    'extra': {
      'flat': true,
      'retrieve_children': false,
      'retrieve_user_props': true,
      'properties': [..._properties],
    },
  },
];
Matcher get _rejected => throwsA(isA<ReadOnlyProbePolicyException>());

void main() {
  test(
    'accepts canonical SDK handshake and exposes immutable method counts',
    () {
      final policy = ReadOnlyProbePolicy();
      policy.validateOutgoing(
        _frame(
          'auth.login_ex',
          params: [
            {
              'mechanism': 'API_KEY_PLAIN',
              'username': 'test-user',
              'api_key': _sentinel,
            },
          ],
        ),
      );
      var id = 1;
      for (final method in ['auth.me', 'system.info', 'core.get_methods']) {
        policy.validateOutgoing(_frame(method, id: 'm0-${++id}'));
      }
      expect(policy.callCounts, {
        'auth.login_ex': 1,
        'auth.me': 1,
        'system.info': 1,
        'core.get_methods': 1,
      });
      expect(() => policy.callCounts.clear(), throwsUnsupportedError);
      expect(policy.callCounts.toString(), isNot(contains(_sentinel)));
      expect(policy.toString(), isNot(contains(_sentinel)));
    },
  );

  for (final method in [
    'auth.me',
    'system.info',
    'system.product_type',
    'core.get_methods',
    'pool.query',
    'pool.dataset.query',
    'service.query',
    'alert.list',
    'core.get_jobs',
    'failover.licensed',
    'interface.has_pending_changes',
    'interface.checkin_waiting',
    'interface.query',
    'network.configuration.config',
    'interface.network_config_to_be_removed',
    'interface.services_restarted_on_sync',
    'app.used_host_ips',
  ]) {
    test('$method accepts absent/null/empty positional params only', () {
      final policy = ReadOnlyProbePolicy();
      policy.validateOutgoing(_frame(method));
      policy.validateOutgoing(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': method,
          'id': 'm0-2',
          'params': null,
        }),
      );
      policy.validateOutgoing(_frame(method, id: 'm0-3', params: []));
      for (final params in [
        {},
        [null],
        [[], {}],
        {'limit': 1},
      ]) {
        expect(
          () => policy.validateOutgoing(
            _frame(method, id: 'm0-4', params: params),
          ),
          _rejected,
        );
      }
      expect(policy.callCounts[method], 3);
    });
  }

  for (final method in [
    'pool.dataset.update',
    'pool.dataset.create',
    'pool.dataset.delete',
    'pool.dataset.attachments',
    'interface.update',
    'interface.commit',
    'interface.checkin',
    'interface.rollback',
    'interface.cancel_rollback',
    'network.configuration.update',
    'reporting.update',
    'reporting.realtime.stats',
    'service.restart',
    'core.job_abort',
    'system.reboot',
    'auth.generate_token',
    'unknown.method',
  ]) {
    test('rejects $method before counting it', () {
      final policy = ReadOnlyProbePolicy();
      expect(() => policy.validateOutgoing(_frame(method)), _rejected);
      expect(policy.callCounts, isEmpty);
    });
  }

  test('login rejects extra fields, wrong mechanism and empty credentials', () {
    for (final login in [
      {
        'mechanism': 'API_KEY_PLAIN',
        'username': 'user',
        'api_key': _sentinel,
        'token': true,
      },
      {'mechanism': 'PASSWORD_PLAIN', 'username': 'user', 'api_key': _sentinel},
      {'mechanism': 'API_KEY_PLAIN', 'username': '', 'api_key': _sentinel},
      {'mechanism': 'API_KEY_PLAIN', 'username': 'user', 'api_key': ''},
      {'mechanism': 'API_KEY_PLAIN', 'username': 'user', 'api_key': 1},
    ]) {
      expect(
        () => ReadOnlyProbePolicy().validateOutgoing(
          _frame('auth.login_ex', params: [login]),
        ),
        _rejected,
      );
    }
  });

  test('dataset properties admits exactly the audited query', () {
    final policy = ReadOnlyProbePolicy();
    policy.validateOutgoing(_frame('pool.dataset.query', params: _dataset()));
    final changes = <void Function(List<Object?>)>[
      (args) => args[0] = [],
      (args) => (args[1] as Map)['limit'] = 1024,
      (args) => (args[1] as Map)['limit'] = 1025.0,
      (args) => (args[1] as Map)['select'] = ['id'],
      (args) => ((args[1] as Map)['extra'] as Map)['retrieve_children'] = true,
      (args) =>
          ((args[1] as Map)['extra'] as Map)['retrieve_user_props'] = false,
      (args) => ((args[1] as Map)['extra'] as Map)['properties'] = ['all'],
      (args) => ((args[1] as Map)['extra'] as Map)['unexpected'] = true,
      (args) => args.add({}),
    ];
    for (final change in changes) {
      final args = _dataset();
      change(args);
      expect(
        () => policy.validateOutgoing(
          _frame('pool.dataset.query', id: 'm0-2', params: args),
        ),
        _rejected,
      );
    }
    expect(policy.callCounts, {'pool.dataset.query': 1});
  });

  test('reporting discovery and bounded SDK histories are accepted', () {
    final policy = ReadOnlyProbePolicy();
    policy.validateOutgoing(_frame('reporting.graphs', params: [[], {}]));
    policy.validateOutgoing(
      _frame(
        'reporting.get_data',
        id: 'm0-2',
        params: _history(end: 1720000060),
      ),
    );
    policy.validateOutgoing(
      _frame(
        'reporting.get_data',
        id: 'm0-3',
        params: _history(
          name: 'interface',
          identifier: 'eno1',
          end: 1720001800,
        ),
      ),
    );
    policy.validateOutgoing(
      _frame(
        'reporting.graph',
        id: 'm0-4',
        params: [
          'demanddatahitpercentage',
          {'start': 1720000000, 'end': 1720000600, 'aggregate': true},
        ],
      ),
    );
    expect(policy.callCounts['reporting.get_data'], 2);
  });

  test('reporting rejects polluted selections, queries and invalid ranges', () {
    final changes = <void Function(List<Object?>)>[
      (args) => args[0] = [],
      (args) => (args[0] as List).add({'name': 'cpu', 'identifier': null}),
      (args) => ((args[0] as List).single as Map)['name'] = 'unknown',
      (args) => ((args[0] as List).single as Map)['extra'] = true,
      (args) => ((args[0] as List).single as Map).remove('identifier'),
      (args) => ((args[0] as List).single as Map)['identifier'] = 'x' * 257,
      (args) => ((args[0] as List).single as Map)['identifier'] = 'eno1\n',
      (args) => (args[1] as Map)['aggregate'] = false,
      (args) => (args[1] as Map)['unit'] = 'YEAR',
      (args) => (args[1] as Map)['end'] = 1720000059,
      (args) => (args[1] as Map)['end'] = 1720001801,
      (args) => (args[1] as Map)['end'] = 1720000000,
      (args) => (args[1] as Map)['start'] = 0,
      (args) => (args[1] as Map)['start'] = 1720000000.0,
      (args) => (args[1] as Map)['start'] = '1720000000',
      (args) {
        (args[1] as Map)['start'] = 1720000000000;
        (args[1] as Map)['end'] = 1720000000600;
      },
      (args) => args.add({}),
    ];
    for (final change in changes) {
      final args = _history();
      change(args);
      expect(
        () => ReadOnlyProbePolicy().validateOutgoing(
          _frame('reporting.get_data', params: args),
        ),
        _rejected,
      );
    }
    for (final name in [
      'cpu',
      'disk',
      'interface',
      'bad.graph',
      'bad/name',
      'bad\n',
      '',
    ]) {
      expect(
        () => ReadOnlyProbePolicy().validateOutgoing(
          _frame('reporting.graph', params: [name, _history()[1]]),
        ),
        _rejected,
      );
    }
    for (final args in [
      [],
      [
        [],
        {'limit': 1},
      ],
      [
        [
          ['name', '=', 'cpu'],
        ],
        {},
      ],
      [[], {}, null],
    ]) {
      expect(
        () => ReadOnlyProbePolicy().validateOutgoing(
          _frame('reporting.graphs', params: args),
        ),
        _rejected,
      );
    }
  });

  test('only the correlated subscription result permits one unsubscribe', () {
    final policy = ReadOnlyProbePolicy();
    policy.validateOutgoing(
      _frame('core.subscribe', params: ['reporting.realtime:{"interval":2}']),
    );
    policy.observeIncoming(
      jsonEncode({'jsonrpc': '2.0', 'id': 'foreign', 'result': 'foreign-sub'}),
    );
    expect(
      () => policy.validateOutgoing(
        _frame('core.unsubscribe', id: 'm0-2', params: ['foreign-sub']),
      ),
      _rejected,
    );
    expect(
      () => policy.validateOutgoing(
        _frame('core.unsubscribe', id: 'm0-2', params: ['own-sub']),
      ),
      _rejected,
    );
    policy.observeIncoming(
      '{"jsonrpc": "2.0", "id": "m0-1", "result": "own-sub"}',
    );
    policy.observeIncoming(
      jsonEncode({'jsonrpc': '2.0', 'id': 'm0-1', 'result': 'replacement'}),
    );
    expect(
      () => policy.validateOutgoing(
        _frame('core.unsubscribe', id: 'm0-2', params: ['replacement']),
      ),
      _rejected,
    );
    policy.validateOutgoing(
      _frame('core.unsubscribe', id: 'm0-2', params: ['own-sub']),
    );
    expect(
      () => policy.validateOutgoing(
        _frame('core.unsubscribe', id: 'm0-3', params: ['own-sub']),
      ),
      _rejected,
    );
    expect(
      () => policy.validateOutgoing(
        _frame(
          'core.subscribe',
          id: 'm0-3',
          params: ['reporting.realtime:{"interval":2}'],
        ),
      ),
      _rejected,
    );
    expect(policy.callCounts, {'core.subscribe': 1, 'core.unsubscribe': 1});
  });

  test('subscription errors, malformed results and other collections cannot authorize cleanup', () {
    for (final collection in [
      'reporting.realtime',
      'reporting.realtime:{"interval":1}',
      'core.get_jobs',
    ]) {
      expect(
        () => ReadOnlyProbePolicy().validateOutgoing(
          _frame('core.subscribe', params: [collection]),
        ),
        _rejected,
      );
    }
    for (final result in [
      null,
      '',
      1,
      {'id': 'sub'},
      's' * 257,
    ]) {
      final policy = ReadOnlyProbePolicy();
      policy.validateOutgoing(
        _frame('core.subscribe', params: ['reporting.realtime:{"interval":2}']),
      );
      expect(
        () => policy.observeIncoming(
          jsonEncode({'jsonrpc': '2.0', 'id': 'm0-1', 'result': result}),
        ),
        _rejected,
      );
      expect(
        () => policy.validateOutgoing(
          _frame('core.unsubscribe', id: 'm0-2', params: ['sub']),
        ),
        _rejected,
      );
    }
    final policy = ReadOnlyProbePolicy();
    policy.validateOutgoing(
      _frame('core.subscribe', params: ['reporting.realtime:{"interval":2}']),
    );
    policy.observeIncoming(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 'm0-1',
        'error': {'code': 1, 'message': _sentinel},
      }),
    );
    policy.observeIncoming(
      jsonEncode({'jsonrpc': '2.0', 'id': 'm0-1', 'result': 'sub'}),
    );
    expect(
      () => policy.validateOutgoing(
        _frame('core.unsubscribe', id: 'm0-2', params: ['sub']),
      ),
      _rejected,
    );
  });

  test('malformed, duplicate-key, batch and extra-field frames fail without leaking', () {
    for (final frame in [
      '{$_sentinel',
      jsonEncode([
        {'method': 'system.info'},
      ]),
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'system.info',
        'id': 'm0-1',
        'secret': _sentinel,
      }),
      '{"jsonrpc":"2.0","method":"system.reboot","method":"system.info","id":"m0-1"}',
      jsonEncode({'jsonrpc': '2.0', 'method': 'system.info'}),
      jsonEncode({'jsonrpc': '1.0', 'method': 'system.info', 'id': 'm0-1'}),
      jsonEncode({'jsonrpc': '2.0', 'method': _sentinel, 'id': 'm0-1'}),
      jsonEncode({'jsonrpc': '2.0', 'method': 'system.info', 'id': null}),
    ]) {
      final policy = ReadOnlyProbePolicy();
      try {
        policy.validateOutgoing(frame);
        fail('Expected a rejection.');
      } on ReadOnlyProbePolicyException catch (error) {
        expect(error.toString(), 'Read-only probe policy rejected a frame.');
        expect(error.toString(), isNot(contains(_sentinel)));
      }
      expect(policy.callCounts, isEmpty);
    }
    expect(
      () => ReadOnlyProbePolicy().observeIncoming('{$_sentinel'),
      _rejected,
    );
  });

  test('reused request IDs cannot confuse subscription correlation', () {
    final policy = ReadOnlyProbePolicy();
    policy.validateOutgoing(_frame('system.info'));
    expect(
      () => policy.validateOutgoing(
        _frame('core.subscribe', params: ['reporting.realtime:{"interval":2}']),
      ),
      _rejected,
    );
    expect(policy.callCounts, {'system.info': 1});
  });
}
