import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import '../support/in_memory_transport.dart';

const _password = ' synthetic password with spaces ';
const _success = {
  'response_type': 'SUCCESS',
  'authenticator': 'LEVEL_1',
  'user_info': null,
};
const _otp = {'response_type': 'OTP_REQUIRED', 'username': 'alice'};

void main() {
  test(
    'PASSWORD_PLAIN preserves exact password and never accesses the key vault',
    () async {
      final h = _Harness();
      final pending = h.connect();
      final login = await h.next();
      expect(login['method'], 'auth.login_ex');
      expect(login['params'], [
        {
          'mechanism': 'PASSWORD_PLAIN',
          'username': 'alice',
          'password': _password,
          'login_options': {'user_info': false},
        },
      ]);
      h.respond(login, _success);
      await h.summary();
      final result = await pending as ServerSummary;
      expect(result.identity, 'alice');
      expect(result.version, '25.10.1');
      expect(result.toString(), isNot(contains(_password)));
      expect(h.vault.accesses, 0);
      expect(h.transport.sentFrames, hasLength(4));
      await h.repo.close();
    },
  );

  for (final input in ['', 'p' * 1025]) {
    test(
      'invalid password length ${input.length} opens no transport',
      () async {
        final h = _Harness();
        final result = await h.connect(password: input);
        expect(result, _failure(PasswordLoginFailure.invalidPassword));
        expect(h.connector.endpoint, isNull);
        expect(h.transport.sentFrames, isEmpty);
        expect(h.vault.accesses, 0);
      },
    );
  }

  for (final state in ['AUTH_ERR', 'EXPIRED', 'REDIRECT', 'NEW_MECHANISM']) {
    test('$state never forwards credentials or reads inventory', () async {
      final h = _Harness();
      final pending = h.connect();
      h.respond(await h.next(), {
        'response_type': state,
        'urls': ['https://untrusted.example/$_password'],
        'message': _password,
      });
      final result = await pending;
      expect(result, isA<PasswordLoginException>());
      expect(result.toString(), isNot(contains(_password)));
      expect(h.transport.sentFrames, hasLength(1));
      expect(h.transport.closeCalls, 1);
      expect(h.repo.managementCapabilities.connected, isFalse);
    });
  }

  for (final malformed in <Object?>[
    true,
    'SUCCESS',
    null,
    {'state': 'SUCCESS'},
    {'response_type': 'SUCCESS'},
    {'response_type': 'SUCCESS', 'authenticator': 'LEVEL_9'},
  ]) {
    test(
      'malformed password reply ${jsonEncode(malformed)} fails closed',
      () async {
        final h = _Harness();
        final pending = h.connect();
        h.respond(await h.next(), malformed);
        expect(await pending, _failure(PasswordLoginFailure.unsupported));
        expect(h.transport.sentFrames, hasLength(1));
      },
    );
  }

  for (final level in ['LEVEL_1', 'LEVEL_2']) {
    test('OTP uses same channel; $level is policy not factor count', () async {
      final h = _Harness();
      final reply = Completer<String?>();
      PasswordOtpChallenge? challenge;
      final pending = h.connect(
        responder: (value) {
          challenge = value;
          return reply.future;
        },
      );
      h.respond(await h.next(), _otp);
      await _until(() => challenge != null);
      expect(challenge!.endpoint, 'wss://nas.example/api/current');
      expect(challenge!.username, 'alice');
      expect(challenge!.attempt, 1);
      expect(h.repo.managementCapabilities.connected, isFalse);
      await expectLater(
        h.repo.query('pool.query'),
        throwsA(isA<SessionQueryException>()),
      );
      expect(h.transport.sentFrames, hasLength(1));
      reply.complete('123456');
      final second = await h.next();
      expect(second['method'], 'auth.login_ex_continue');
      expect(second['params'], [
        {
          'mechanism': 'OTP_TOKEN',
          'otp_token': '123456',
          'login_options': {'user_info': false},
        },
      ]);
      expect(second.toString(), isNot(contains(_password)));
      h.respond(second, {..._success, 'authenticator': level});
      await h.summary();
      expect(await pending, isA<ServerSummary>());
      expect(h.vault.accesses, 0);
      await h.repo.close();
    });
  }

  test(
    'manual OTP retry is prompted and bounded to three distinct submissions',
    () async {
      final h = _Harness();
      final prompts = <int>[];
      final pending = h.connect(
        responder: (c) async {
          prompts.add(c.attempt);
          return '123456';
        },
      );
      h.respond(await h.next(), _otp);
      for (var i = 0; i < 3; i++) {
        final next = await h.next();
        expect(next['method'], 'auth.login_ex_continue');
        h.respond(next, _otp);
      }
      expect(await pending, _failure(PasswordLoginFailure.rejected));
      expect(prompts, [1, 2, 3]);
      expect(h.transport.sentFrames, hasLength(4));
    },
  );

  test('server account cannot change between OTP attempts', () async {
    final h = _Harness();
    var prompts = 0;
    final pending = h.connect(
      responder: (_) async {
        prompts++;
        return '123456';
      },
    );
    h.respond(await h.next(), _otp);
    h.respond(await h.next(), {..._otp, 'username': 'bob'});
    expect(await pending, _failure(PasswordLoginFailure.unsupported));
    expect(prompts, 1);
  });

  for (final account in <Object?>[null, '', 'bad\nname', 7]) {
    test('malformed OTP username $account does not prompt', () async {
      final h = _Harness();
      var prompts = 0;
      final pending = h.connect(
        responder: (_) async {
          prompts++;
          return '123456';
        },
      );
      h.respond(await h.next(), {..._otp, 'username': account});
      expect(await pending, _failure(PasswordLoginFailure.unsupported));
      expect(prompts, 0);
    });
  }

  for (final token in <String?>[
    null,
    '',
    '12345',
    '123456789',
    ' 123456',
    '123456\n',
    'abcdef',
  ]) {
    test(
      'cancelled or invalid OTP ${jsonEncode(token)} is never dispatched',
      () async {
        final h = _Harness();
        final pending = h.connect(responder: (_) async => token);
        h.respond(await h.next(), _otp);
        expect(
          await pending,
          _failure(
            token == null
                ? PasswordLoginFailure.cancelled
                : PasswordLoginFailure.invalidOtp,
          ),
        );
        expect(h.transport.sentFrames, hasLength(1));
        expect(h.transport.closeCalls, 1);
      },
    );
  }

  test(
    'OTP without responder closes rather than bypassing the challenge',
    () async {
      final h = _Harness();
      final pending = h.connect();
      h.respond(await h.next(), _otp);
      expect(await pending, _failure(PasswordLoginFailure.rejected));
      expect(h.transport.sentFrames, hasLength(1));
    },
  );

  test('prompt timeout closes and late code cannot send', () async {
    final h = _Harness(challengeTimeout: const Duration(milliseconds: 20));
    final reply = Completer<String?>();
    final pending = h.connect(responder: (_) => reply.future);
    h.respond(await h.next(), _otp);
    expect(await pending, _failure(PasswordLoginFailure.timeout));
    reply.complete('123456');
    await Future<void>.delayed(Duration.zero);
    expect(h.transport.sentFrames, hasLength(1));
    expect(h.transport.closeCalls, 1);
  });

  test(
    'close while waiting prevents late OTP and summary publication',
    () async {
      final h = _Harness();
      final reply = Completer<String?>();
      var prompted = false;
      final pending = h.connect(
        responder: (_) {
          prompted = true;
          return reply.future;
        },
      );
      h.respond(await h.next(), _otp);
      await _until(() => prompted);
      await h.repo.close();
      reply.complete('123456');
      expect(await pending, isA<CredentialUnavailableException>());
      expect(h.transport.sentFrames, hasLength(1));
      expect(h.transport.closeCalls, 1);
    },
  );

  test('external connection fence changes while awaiting code', () async {
    final h = _Harness();
    final reply = Completer<String?>();
    var prompted = false, current = true;
    final pending = h.connect(
      responder: (_) {
        prompted = true;
        return reply.future;
      },
      current: () => current,
    );
    h.respond(await h.next(), _otp);
    await _until(() => prompted);
    current = false;
    reply.complete('123456');
    expect(await pending, isA<CredentialUnavailableException>());
    expect(h.transport.sentFrames, hasLength(1));
  });

  test('login RPC timeout does not retry password', () async {
    final h = _Harness(requestTimeout: const Duration(milliseconds: 20));
    final pending = h.connect();
    await h.next();
    expect(await pending, _failure(PasswordLoginFailure.timeout));
    expect(h.transport.sentFrames, hasLength(1));
    expect(h.transport.closeCalls, 1);
  });

  for (final step in [
    'auth.login_ex',
    'auth.me',
    'system.info',
    'core.get_methods',
  ]) {
    test(
      'remote error at $step cannot expose credential or server diagnostics',
      () async {
        final h = _Harness();
        final pending = h.connect();
        for (final method in [
          'auth.login_ex',
          'auth.me',
          'system.info',
          'core.get_methods',
        ]) {
          final request = await h.next();
          expect(request['method'], method);
          if (method == step) {
            h.reject(request);
            break;
          }
          h.respond(request, switch (method) {
            'auth.login_ex' => _success,
            'auth.me' => {'pw_name': 'alice'},
            'system.info' => {'version': '25.10.1'},
            _ => {},
          });
        }
        final result = await pending;
        expect(result, isA<PasswordLoginException>());
        expect(result.toString(), isNot(contains(_password)));
        expect(h.repo.managementCapabilities.connected, isFalse);
        expect(h.vault.accesses, 0);
      },
    );
  }

  test('unsupported release never publishes capabilities', () async {
    final h = _Harness();
    final pending = h.connect();
    h.respond(await h.next(), _success);
    h.respond(await h.next(), {'pw_name': 'alice'});
    h.respond(await h.next(), {'version': '26.0'});
    expect(await pending, _failure(PasswordLoginFailure.unsupported));
    expect(h.transport.sentFrames, hasLength(3));
    expect(h.repo.managementCapabilities.connected, isFalse);
  });
}

Matcher _failure(PasswordLoginFailure reason) =>
    isA<PasswordLoginException>().having((e) => e.reason, 'reason', reason);

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'Expected bounded fake-wire progress');
}

class _Harness {
  _Harness({
    Duration requestTimeout = const Duration(seconds: 1),
    Duration challengeTimeout = const Duration(seconds: 1),
  }) {
    repo = TrueNasSessionRepository(
      connector: connector,
      credentialVault: vault,
      authenticationRequestTimeout: requestTimeout,
      otpChallengeTimeout: challengeTimeout,
    );
  }
  final transport = InMemoryTransport();
  final vault = _NoVault();
  late final connector = FakeConnector(transport);
  late final TrueNasSessionRepository repo;
  var consumed = 0;
  Future<Object> connect({
    String password = _password,
    PasswordOtpResponder? responder,
    bool Function()? current,
  }) async {
    try {
      return await repo.connectWithPassword(
        serverInput: 'https://nas.example',
        password: password,
        username: 'alice',
        onOtpRequired: responder,
        isConnectionCurrent: current,
      );
    } on Object catch (error) {
      return error;
    }
  }

  Future<Map<String, Object?>> next() async {
    await _until(() => transport.sentFrames.length > consumed);
    return (jsonDecode(transport.sentFrames[consumed++]) as Map)
        .cast<String, Object?>();
  }

  void respond(Map request, Object? value) => transport.add(
    jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': value}),
  );
  void reject(Map request) => transport.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': request['id'],
      'error': {
        'code': -32001,
        'message': _password,
        'data': {'password': _password},
      },
    }),
  );
  Future<void> summary() async {
    final me = await next();
    expect(me['method'], 'auth.me');
    respond(me, {'pw_name': 'alice'});
    final info = await next();
    expect(info['method'], 'system.info');
    respond(info, {'version': '25.10.1'});
    final methods = await next();
    expect(methods['method'], 'core.get_methods');
    respond(methods, {'pool.query': {}});
  }
}

class _NoVault implements CredentialVault {
  var accesses = 0;
  @override
  Future<String?> readApiKey(String endpointIdentifier) async {
    accesses++;
    throw StateError('Forbidden vault read');
  }

  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async {
    accesses++;
    throw StateError('Forbidden vault write');
  }

  @override
  Future<void> deleteApiKey(String endpointIdentifier) async {
    accesses++;
    throw StateError('Forbidden vault deletion');
  }
}
