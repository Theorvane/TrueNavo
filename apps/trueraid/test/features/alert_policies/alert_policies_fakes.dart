import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/alert_policies/alert_policies_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import '../alert_settings/alert_settings_fakes.dart'
    show alertInventory, alertEndpoint;

const policiesCaps = AlertPoliciesCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canUpdate: true,
  canReadSupportEligibility: true,
);
const policyClasses = [
  AlertClassPolicySnapshot(
    id: 'DiskTemp',
    title: 'Disk temperature',
    categoryId: 'HARDWARE',
    categoryTitle: 'Hardware',
    defaultLevel: AlertDeliveryLevel.warning,
    supportsProactiveSupport: true,
    hasOverride: true,
    overrides: AlertClassOverrides(
      policy: AlertPolicyFrequency.hourly,
      proactiveSupport: false,
    ),
  ),
  AlertClassPolicySnapshot(
    id: 'SpaceLow',
    title: 'Available space',
    categoryId: 'STORAGE',
    categoryTitle: 'Storage',
    defaultLevel: AlertDeliveryLevel.critical,
    supportsProactiveSupport: false,
    hasOverride: false,
  ),
];
AlertPoliciesInventory policiesInventory({
  String? hostId,
  String endpoint = alertEndpoint,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  List<AlertClassPolicySnapshot> classes = policyClasses,
  bool? available = true,
  bool? enabled = true,
}) => AlertPoliciesInventory(
  readiness: alertInventory(
    endpoint: endpoint,
    hostId:
        hostId ??
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    admin: admin,
    ha: ha,
    jobs: jobs,
    healthy: healthy,
    services: const [],
  ),
  configId: 1,
  classes: classes,
  unlistedOverrideCount: 2,
  supportAvailable: available,
  supportEnabled: enabled,
);
AlertPoliciesRequest policiesRequest(
  AlertPoliciesInventory inventory, {
  bool reset = false,
  bool never = false,
  bool support = false,
}) => AlertPoliciesRequest(
  inventory: inventory,
  classPolicy: inventory.classes.first,
  action: reset
      ? AlertPoliciesAction.resetClass
      : AlertPoliciesAction.configure,
  proactiveSupportDisclosureAccepted: true,
  overrides: reset
      ? null
      : AlertClassOverrides(
          level: AlertDeliveryLevel.error,
          policy: never
              ? AlertPolicyFrequency.never
              : AlertPolicyFrequency.hourly,
          proactiveSupport: support ? true : false,
        ),
);

class PoliciesFake
    implements SessionRepository, AuthenticatedAlertPoliciesSession {
  PoliciesFake({AlertPoliciesInventory? inventory, this.caps = policiesCaps})
    : inventory = inventory ?? policiesInventory();
  AlertPoliciesInventory inventory;
  AlertPoliciesCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <AlertPoliciesRequest>[], executes = <AlertPoliciesReview>[];
  Future<AlertPoliciesInventory> Function()? onLoad;
  Future<AlertPoliciesReview> Function(AlertPoliciesRequest)? onReview;
  Future<AlertPoliciesResult> Function(AlertPoliciesReview, bool Function())?
  onExecute;
  @override
  AlertPoliciesCapabilities get alertPoliciesCapabilities => caps;
  @override
  Future<AlertPoliciesInventory> loadAlertPolicies() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<AlertPoliciesReview> reviewAlertPolicies(
    AlertPoliciesRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        AlertPoliciesReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic full-map preservation details. No live server contact.',
          ],
        );
  }

  @override
  Future<AlertPoliciesResult> executeAlertPolicies(
    AlertPoliciesReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(review);
    if (onExecute != null) return onExecute!(review, isCurrent);
    if (isCurrent()) mutations++;
    return const AlertPoliciesResult(
      AlertPoliciesOutcome.completed,
      'Synthetic config verification',
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
  }) => throw UnsupportedError('Synthetic policies only');
}

class PoliciesHarness {
  PoliciesHarness({PoliciesFake? fake}) : api = fake ?? PoliciesFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final PoliciesFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = alertEndpoint}) =>
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

  Future<void> load() => container.read(alertPoliciesInventoryProvider.future);
  void dispose() => container.dispose();
}
