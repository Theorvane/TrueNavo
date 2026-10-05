import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const sshEndpoint = 'wss://sample.example/api/current';
const sshPublic =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB';
List<int> _number(int n) => [
  n >> 24 & 255,
  n >> 16 & 255,
  n >> 8 & 255,
  n & 255,
];
List<int> _string(List<int> value) => [..._number(value.length), ...value];

/// Deliberately non-cryptographic private body; only client envelope validation
/// succeeds. The fake session never connects or calls a real ssh-keygen.
final sshSyntheticPrivate =
    '-----BEGIN OPENSSH PRIVATE KEY-----\n${base64Encode([...utf8.encode('openssh-key-v1\x00'), ..._string(utf8.encode('none')), ..._string(utf8.encode('none')), ..._string([]), ..._number(1), ..._string(base64Decode(sshPublic.split(' ')[1])), ..._string(utf8.encode('SYNTHETIC NOT A PRIVATE KEY'))])}\n-----END OPENSSH PRIVATE KEY-----';
SshCredentialWriteOnlyInput sshInput() =>
    SshCredentialWriteOnlyInput.keyPair(privateKey: sshSyntheticPrivate);
const sshCaps = SshCredentialsCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canImport: true,
  canGenerate: true,
  canCreateConnection: true,
  canRename: true,
  canDelete: true,
);
const sshConnection = SshConnectionSettings(
  host: 'archive.example',
  port: 22,
  username: 'backup',
  keyPairId: 1,
  remoteHostKey: sshPublic,
  connectTimeout: 10,
);
SshCredentialInventory sshInventory({
  bool empty = false,
  bool conflict = false,
}) => SshCredentialInventory(
  endpoint: sshEndpoint,
  conflictingJob: conflict,
  credentials: empty
      ? []
      : [
          const SshCredentialEntry(
            id: 1,
            name: 'Referenced identity',
            type: 'SSH_KEY_PAIR',
            usageCount: 1,
            publicKey: sshPublic,
          ),
          const SshCredentialEntry(
            id: 2,
            name: 'Unused identity',
            type: 'SSH_KEY_PAIR',
            usageCount: 0,
            publicKey: sshPublic,
          ),
          const SshCredentialEntry(
            id: 3,
            name: 'Archive destination',
            type: 'SSH_CREDENTIALS',
            usageCount: 0,
            connection: sshConnection,
          ),
        ],
);
SshCredentialReview sshReview(
  SshCredentialInventory inventory, {
  SshCredentialAction action = SshCredentialAction.generateKeyPair,
}) => SshCredentialReview(
  request: SshCredentialRequest(
    inventory: inventory,
    action: action,
    name: 'New identity',
  ),
  endpoint: sshEndpoint,
  warnings: const [
    'No remote SSH connection is performed.',
    'This change has server-side effects and must not be replayed.',
  ],
);

class SshFake implements SessionRepository, AuthenticatedSshCredentialsSession {
  SshFake({SshCredentialInventory? inventory, this.caps = sshCaps})
    : inventory = inventory ?? sshInventory();
  final SshCredentialInventory inventory;
  final SshCredentialsCapabilities caps;
  int reads = 0;
  final reviews = <SshCredentialRequest>[], writes = <SshCredentialReview>[];
  final inputs = <SshCredentialWriteOnlyInput?>[];
  Future<SshCredentialInventory> Function()? onLoad;
  Future<SshCredentialReview> Function(SshCredentialRequest)? onReview;
  Future<SshCredentialResult> Function()? onExecute;
  @override
  SshCredentialsCapabilities get sshCredentialsCapabilities => caps;
  @override
  Future<SshCredentialInventory> loadSshCredentials() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<SshCredentialReview> reviewSshCredential(
    SshCredentialRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        SshCredentialReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'No remote SSH connection is performed.',
            'This change has server-side effects and must not be replayed.',
          ],
        );
  }

  @override
  Future<SshCredentialResult> executeSshCredential(
    SshCredentialReview review,
    String confirmation, {
    SshCredentialWriteOnlyInput? input,
  }) async {
    writes.add(review);
    inputs.add(input);
    return onExecute?.call() ??
        const SshCredentialResult(
          SshCredentialOutcome.succeeded,
          'Synthetic configuration confirmed.',
          publicKey: sshPublic,
        );
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('No connector in fixtures.');
}

class SshHarness {
  SshHarness({SshFake? fake}) : api = fake ?? SshFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final SshFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = sshEndpoint}) =>
      AuthenticatedSession(
        profileId: 'sample',
        repository: api,
        availableMethodNames: const {},
        version: '25.10.1',
        endpoint: endpoint,
      );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}
