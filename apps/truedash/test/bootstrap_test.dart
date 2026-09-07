import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/bootstrap.dart';
import 'package:truedash/features/server_profiles/server_profile_store.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';

void main() {
  testWidgets('opens and hydrates before rendering, then closes once', (
    tester,
  ) async {
    final store = _Store();
    var renders = 0;
    await bootstrapTrueDash(
      openStore: () async => store,
      run: (app) async {
        renders++;
        await tester.pumpWidget(app);
      },
    );
    expect(store.loads, 1);
    expect(renders, 1);
    await tester.pumpWidget(const SizedBox());
    expect(store.closes, 1);
  });

  test(
    'open/load failure has a stable safe startup failure and closes once',
    () async {
      final store = _Store()..failLoad = true;
      await expectLater(
        bootstrapTrueDash(openStore: () async => store, run: (_) async {}),
        throwsA(isA<StartupFailure>()),
      );
      expect(store.closes, 1);
    },
  );

  test('open failure exposes no implementation detail', () async {
    await expectLater(
      bootstrapTrueDash(
        openStore: () async => throw StateError('/secret/path/sqlite'),
        run: (_) async {},
      ),
      throwsA(
        isA<StartupFailure>().having(
          (failure) => failure.toString(),
          'safe message',
          StartupFailure.message,
        ),
      ),
    );
  });

  test('run failure before mounting closes the unowned store', () async {
    final store = _Store();

    await expectLater(
      bootstrapTrueDash(
        openStore: () async => store,
        run: (_) => throw StateError('mount failed'),
      ),
      throwsA(isA<StartupFailure>()),
    );

    expect(store.closes, 1);
  });

  testWidgets('run failure after mounting leaves closing to the root', (
    tester,
  ) async {
    final store = _Store();

    await expectLater(
      bootstrapTrueDash(
        openStore: () async => store,
        run: (app) async {
          await tester.pumpWidget(app);
          throw StateError('after mount');
        },
      ),
      throwsA(isA<StartupFailure>()),
    );
    expect(store.closes, 0);

    await tester.pumpWidget(const SizedBox());
    expect(store.closes, 1);
  });
}

final class _Store implements ServerProfileStore {
  int loads = 0;
  int closes = 0;
  bool failLoad = false;
  @override
  Future<ServerProfileSnapshot> load() async {
    loads++;
    if (failLoad) throw StateError('/secret/path/sqlite');
    return ServerProfileSnapshot(profiles: const [], selectedProfileId: null);
  }

  @override
  Future<ServerProfileSnapshot> registerAndSelect(
    ServerProfile profile,
  ) async => await load();
  @override
  Future<ServerProfileSnapshot> select(String id) async => await load();
  @override
  Future<ServerProfileSnapshot> remove(String id) async => await load();
  @override
  Future<void> replaceCapabilities({
    required String profileId,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
  }) async {}
  @override
  Future<Set<String>> readCapabilities(String profileId, DateTime now) async =>
      const {};
  @override
  Future<void> close() async => closes++;
}
