import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

import 'connection_controller.dart';
import 'connection_state.dart';
import '../tls_trust/certificate_facts.dart';
import '../tls_trust/certificate_trust_coordinator.dart';
import '../tls_trust/tls_trust_providers.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key, this.onConnectionSucceeded});

  final VoidCallback? onConnectionSucceeded;

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _url = TextEditingController();
  final _apiKey = TextEditingController();
  bool _showKey = false;
  bool _rememberApiKey = false;

  @override
  void dispose() {
    _url.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ConnectionState>(connectionControllerProvider, (_, next) {
      if (next is ConnectionSucceeded && widget.onConnectionSucceeded != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onConnectionSucceeded!();
        });
      }
    });
    final state = ref.watch(connectionControllerProvider);
    final busy = state is ConnectionInProgress;
    final browserManaged =
        ref.watch(tlsTrustRouteProvider) == TlsTrustRoute.browserManaged;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final expanded = constraints.maxWidth >= 1000;
            final pagePadding = expanded
                ? TdSpacing.pageDesktop
                : TdSpacing.pageMobile;
            final form = _form(
              context,
              state,
              busy,
              browserManaged: browserManaged,
              showIntroduction: !expanded,
            );
            return SingleChildScrollView(
              key: const Key('connection-scroll-view'),
              padding: EdgeInsets.all(pagePadding),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: expanded
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _IntroPane(
                                key: const Key('connection-intro-pane'),
                              ),
                            ),
                            const SizedBox(width: TdSpacing.sectionDesktop),
                            Expanded(child: form),
                          ],
                        )
                      : form,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _form(
    BuildContext context,
    ConnectionState state,
    bool busy, {
    required bool showIntroduction,
    required bool browserManaged,
  }) => TdPanel(
    key: const Key('connection-form-pane'),
    padding: const EdgeInsets.all(TdSpacing.group),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showIntroduction) const _MobileHeader(),
        TdTextField(
          label: 'Server URL',
          fieldKey: const Key('server-url-field'),
          controller: _url,
          hintText: 'https://nas.example:8443',
          prefixIcon: Icons.link,
          keyboardType: TextInputType.url,
          enabled: !busy,
        ),
        const SizedBox(height: TdSpacing.component),
        TdTextField(
          label: 'API key',
          fieldKey: const Key('api-key-field'),
          controller: _apiKey,
          prefixIcon: Icons.key_outlined,
          enabled: !busy,
          secret: true,
          obscureText: !_showKey,
          onToggleSecret: () => setState(() => _showKey = !_showKey),
        ),
        const SizedBox(height: TdSpacing.related),
        if (browserManaged)
          Text(
            'This browser does not persist API keys.',
            style: TdTypography.bodyLarge.copyWith(
              color: context.tdTheme.textSecondary,
            ),
          )
        else ...[
          _RememberApiKeyControl(
            value: _rememberApiKey,
            enabled: !busy,
            onChanged: (value) => setState(() => _rememberApiKey = value),
          ),
        ],
        const SizedBox(height: TdSpacing.group),
        TdButton(
          key: const Key('connect-button'),
          label: busy ? 'Connecting securely…' : 'Connect',
          icon: Icons.lock_open_rounded,
          isLoading: busy,
          expand: true,
          onPressed: busy
              ? null
              : () => ref
                    .read(connectionControllerProvider.notifier)
                    .connect(
                      serverInput: _url.text,
                      apiKey: _apiKey.text,
                      rememberApiKey: !browserManaged && _rememberApiKey,
                    ),
        ),
        if (state is ConnectionTrustReview) ...[
          const SizedBox(height: TdSpacing.group),
          _TrustReviewPanel(
            review: state,
            busy: busy,
            onApprove: () => ref
                .read(connectionControllerProvider.notifier)
                .approveTrust(
                  apiKey: _apiKey.text,
                  rememberApiKey: !browserManaged && _rememberApiKey,
                ),
            onCancel: () =>
                ref.read(connectionControllerProvider.notifier).cancelTrust(),
          ),
        ],
        if (state is ConnectionTrustBlocked) ...[
          const SizedBox(height: TdSpacing.group),
          TdStateView(
            kind: TdStateKind.error,
            title: 'Secure connection is blocked',
            description: _trustFailureDescription(state.failure),
            compact: true,
          ),
          const SizedBox(height: TdSpacing.related),
          TdButton(
            key: const Key('retry-trust-button'),
            label: 'Retry secure connection',
            expand: true,
            onPressed: busy
                ? null
                : () => ref
                      .read(connectionControllerProvider.notifier)
                      .retryTrust(
                        apiKey: _apiKey.text,
                        rememberApiKey: !browserManaged && _rememberApiKey,
                      ),
          ),
        ],
        if (state case ConnectionFailed(:final message)) ...[
          const SizedBox(height: TdSpacing.group),
          TdStateView(
            kind: TdStateKind.error,
            title: 'Connection could not be completed',
            description: message,
            compact: true,
          ),
        ],
      ],
    ),
  );
}

class _TrustReviewPanel extends StatelessWidget {
  const _TrustReviewPanel({
    required this.review,
    required this.busy,
    required this.onApprove,
    required this.onCancel,
  });

  final ConnectionTrustReview review;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final certificate = switch (review) {
      ConnectionFirstTrustReview(:final certificate) => certificate,
      ConnectionReplacementTrustReview(:final certificate) => certificate,
    };
    final previous = switch (review) {
      ConnectionReplacementTrustReview(:final previousPin) => previousPin,
      _ => null,
    };
    final valid =
        _hasCompleteReviewFacts(certificate) &&
        _isValidFingerprint(certificate.leafDerSha256) &&
        (previous == null ||
            (_isValidFingerprint(previous.leafDerSha256) &&
                previous.leafDerSha256 != certificate.leafDerSha256));
    return TdPanel(
      key: const Key('trust-review-panel'),
      padding: const EdgeInsets.all(TdSpacing.related),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            previous == null
                ? 'Review server certificate'
                : 'Certificate replacement review',
            style: TdTypography.titleSmall.copyWith(
              color: context.tdTheme.textPrimary,
            ),
          ),
          const SizedBox(height: TdSpacing.related),
          _TrustFact(label: 'Server', value: review.authority.pinKey),
          _TrustFact(label: 'Subject', value: certificate.subjectSummary),
          _TrustFact(label: 'Issuer', value: certificate.issuerSummary),
          _TrustFact(
            label: 'Valid from',
            value: _formatTrustDate(certificate.notValidBefore),
          ),
          _TrustFact(
            label: 'Valid to',
            value: _formatTrustDate(certificate.notValidAfter),
          ),
          _TrustFact(
            label: 'Platform trust',
            value: _platformTrustLabel(certificate.platformTrust),
          ),
          if (previous == null)
            _FingerprintFact(
              label: 'SHA-256 fingerprint',
              value: certificate.leafDerSha256,
              fieldKey: const Key('current-fingerprint'),
            )
          else ...[
            _FingerprintFact(
              label: 'Previous fingerprint',
              value: previous.leafDerSha256,
              fieldKey: const Key('previous-fingerprint'),
            ),
            _FingerprintFact(
              label: 'New fingerprint',
              value: certificate.leafDerSha256,
              fieldKey: const Key('new-fingerprint'),
            ),
          ],
          const SizedBox(height: TdSpacing.related),
          if (!valid)
            const TdStateView(
              kind: TdStateKind.error,
              title: 'Certificate review details are unavailable.',
              description:
                  'This certificate cannot be approved. Cancel and try again.',
              compact: true,
            )
          else
            TdButton(
              key: const Key('approve-trust-button'),
              label: 'Trust and connect',
              expand: true,
              onPressed: busy ? null : onApprove,
            ),
          const SizedBox(height: TdSpacing.inline),
          TdButton(
            key: const Key('cancel-trust-review-button'),
            label: 'Cancel review',
            variant: TdButtonVariant.secondary,
            expand: true,
            onPressed: busy ? null : onCancel,
          ),
        ],
      ),
    );
  }
}

class _TrustFact extends StatelessWidget {
  const _TrustFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: TdSpacing.inlineTight),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TdTypography.label),
        Text(
          value,
          style: TdTypography.body.copyWith(color: context.tdTheme.textPrimary),
        ),
      ],
    ),
  );
}

class _FingerprintFact extends StatelessWidget {
  const _FingerprintFact({
    required this.label,
    required this.value,
    required this.fieldKey,
  });

  final String label;
  final String value;
  final Key fieldKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: TdSpacing.inlineTight),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TdTypography.label),
        SelectableText(
          value,
          key: fieldKey,
          style: TdTypography.monoBody.copyWith(
            color: context.tdTheme.textPrimary,
          ),
        ),
      ],
    ),
  );
}

bool _isValidFingerprint(String value) =>
    RegExp(r'^[A-Fa-f0-9]{64}$').hasMatch(value);

bool _hasCompleteReviewFacts(TrustReviewCertificate certificate) =>
    certificate.subjectSummary.trim().isNotEmpty &&
    certificate.issuerSummary.trim().isNotEmpty &&
    !certificate.notValidBefore.isAfter(certificate.notValidAfter) &&
    certificate.platformTrust != PlatformTrust.notAvailable;

String _platformTrustLabel(PlatformTrust trust) => switch (trust) {
  PlatformTrust.passed => 'Passed',
  PlatformTrust.didNotPass => 'Did not pass',
  PlatformTrust.notAvailable => 'Not available',
};

String _formatTrustDate(DateTime value) {
  final utc = value.toUtc();
  String twoDigits(int component) => component.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${twoDigits(utc.month)}-${twoDigits(utc.day)} '
      '${twoDigits(utc.hour)}:${twoDigits(utc.minute)}:'
      '${twoDigits(utc.second)} UTC';
}

String _trustFailureDescription(CertificateTrustCoordinatorFailure failure) =>
    switch (failure) {
      CertificateTrustCoordinatorFailure.pinMismatch ||
      CertificateTrustCoordinatorFailure.pinnedReconnectFailed =>
        'The pinned certificate could not be verified.',
      CertificateTrustCoordinatorFailure.hostnameMismatch =>
        'The server certificate does not match this server address.',
      CertificateTrustCoordinatorFailure.expiredCertificate =>
        'The server certificate has expired.',
      CertificateTrustCoordinatorFailure.notYetValidCertificate =>
        'The server certificate is not valid yet.',
      CertificateTrustCoordinatorFailure.malformedCertificate =>
        'The server certificate could not be read safely.',
      CertificateTrustCoordinatorFailure.probeTimedOut =>
        'The certificate check timed out.',
      CertificateTrustCoordinatorFailure.cancelled =>
        'The certificate review was cancelled.',
      _ => 'The secure certificate check could not be completed.',
    };

class _RememberApiKeyControl extends StatelessWidget {
  const _RememberApiKeyControl({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    key: const Key('remember-api-key-control'),
    container: true,
    checked: value,
    enabled: enabled,
    label: 'Remember API key on this device',
    hint: enabled
        ? 'Storage uses this device\'s protected credential store.'
        : 'Unavailable while connecting.',
    onTap: enabled ? () => onChanged(!value) : null,
    child: ExcludeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: TdSizing.minimumTouchTarget,
        ),
        child: InkWell(
          onTap: enabled ? () => onChanged(!value) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: TdSpacing.inlineTight,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: value,
                  onChanged: enabled ? (_) => onChanged(!value) : null,
                ),
                const SizedBox(width: TdSpacing.inline),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Remember API key on this device'),
                      const SizedBox(height: TdSpacing.inlineTight),
                      Text(
                        'Storage uses this device\'s protected credential store.',
                        style: TdTypography.bodyLarge.copyWith(
                          color: context.tdTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _IntroPane extends StatelessWidget {
  const _IntroPane({super.key});
  @override
  Widget build(BuildContext context) =>
      TdPanel(child: const _ConnectionIntroduction());
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: TdSpacing.group),
    child: _ConnectionIntroduction(),
  );
}

class _ConnectionIntroduction extends StatelessWidget {
  const _ConnectionIntroduction();
  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: TdSpacing.related,
          runSpacing: TdSpacing.inline,
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.storage_rounded,
                color: td.actionPrimary,
                size: TdSizing.icon,
              ),
            ),
            Text(
              'TrueDash',
              style: TdTypography.titleLarge.copyWith(color: td.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: TdSpacing.related),
        Text(
          'Unofficial TrueNAS client',
          style: TdTypography.titleSmall.copyWith(color: td.textPrimary),
        ),
        const SizedBox(height: TdSpacing.inline),
        Text(
          'Connect directly to a secure HTTPS or WSS endpoint. Your API key is never shown in the result. On supported devices, you can explicitly choose protected credential storage.',
          style: TdTypography.bodyLarge.copyWith(color: td.textSecondary),
        ),
      ],
    );
  }
}
