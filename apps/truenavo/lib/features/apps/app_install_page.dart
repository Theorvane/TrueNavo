import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../admin/admin_schema_form.dart';
import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'apps_controller.dart';
import 'apps_page.dart';

class AppInstallPage extends ConsumerStatefulWidget {
  const AppInstallPage({
    required this.session,
    required this.app,
    this.upgrading,
    super.key,
  });
  final AuthenticatedSession session;
  final CatalogApp app;
  final InstalledApp? upgrading;
  @override
  ConsumerState<AppInstallPage> createState() => _AppInstallPageState();
}

class _AppInstallPageState extends ConsumerState<AppInstallPage> {
  final _form = GlobalKey<AdminSchemaFormState>();
  final _name = TextEditingController();
  String? _version;
  String? _error;
  bool _reviewing = false;
  @override
  void initState() {
    super.initState();
    _name.text = widget.upgrading?.name ?? widget.app.name;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = identical(
      widget.session,
      ref.watch(dashboardActiveSessionProvider),
    );
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (!identical(next, widget.session)) {
        _form.currentState?.clearSensitiveValues();
      }
    });
    final state = ref.watch(appsControllerProvider);
    final upgrading = widget.upgrading != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(upgrading ? 'Upgrade application' : 'Install application'),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(widget.app.title, style: TdTypography.titleLarge),
                const SizedBox(height: 8),
                Text('${widget.app.train} · ${widget.app.name}'),
                const SizedBox(height: 12),
                Text(widget.app.description),
                const SizedBox(height: 20),
                const AppsOperationBanner(),
                if (!current)
                  const TdPanel(
                    title: 'Connection changed',
                    child: Text(
                      'This form belongs to another authenticated session. Return and reload the catalog.',
                    ),
                  )
                else ...[
                  Text(
                    widget.session.endpoint ??
                        'Authenticated endpoint unavailable',
                  ),
                  const SizedBox(height: 12),
                  if (!upgrading)
                    TextField(
                      key: const Key('app-install-name'),
                      controller: _name,
                      enabled: !upgrading && !state.locked && !_reviewing,
                      decoration: const InputDecoration(
                        labelText: 'Application name',
                        helperText: 'Lowercase letters, digits and hyphens; maximum 40 characters.',
                      ),
                    ),
                  if (upgrading)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Installed version · ${widget.upgrading!.version}\n'
                        'Choose an eligible concrete version. The server will preserve and migrate existing configuration. '
                        'No installation defaults or configuration overrides are submitted.',
                      ),
                    ),
                  const SizedBox(height: 16),
                  ref
                      .watch(appVersionsProvider(widget.app))
                      .when(
                        loading: () => const LinearProgressIndicator(),
                        error: (_, _) => TdPanel(
                          title: 'Versions unavailable',
                          child: TextButton(
                            onPressed: () =>
                                ref.invalidate(appVersionsProvider(widget.app)),
                            child: const Text('Reload versions'),
                          ),
                        ),
                        data: (versions) => versions.isEmpty
                            ? const Text('No versions available.')
                            : DropdownButtonFormField<String>(
                                key: const Key('app-version'),
                                initialValue: versions.contains(_version)
                                    ? _version
                                    : null,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Catalog version',
                                ),
                                items: versions
                                    .map(
                                      (version) => DropdownMenuItem(
                                        value: version,
                                        child: Text(
                                          version,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: state.locked || _reviewing
                                    ? null
                                    : (version) {
                                        _form.currentState
                                            ?.clearSensitiveValues();
                                        setState(() {
                                          _version = version;
                                          _error = null;
                                        });
                                      },
                              ),
                      ),
                  const SizedBox(height: 20),
                  if (_version != null)
                    ref
                        .watch(
                          appVersionDetailsProvider((widget.app, _version!)),
                        )
                        .when(
                          loading: () => const LinearProgressIndicator(),
                          error: (_, _) => const TdPanel(
                            title: 'Version details unavailable',
                            child: Text(
                              'The version schema could not be loaded safely. Choose another version or reload the catalog.',
                            ),
                          ),
                          data: (details) => _details(
                            details,
                            enabled: !state.locked && !_reviewing,
                          ),
                        ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _details(AppVersionDetails details, {required bool enabled}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TdPanel(
        title: 'Version ${details.humanVersion}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Installing or upgrading downloads and runs application code. '
              'Configured ports and storage can expose services and grant access to NAS data.',
            ),
            for (final warning in details.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(warning),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (widget.upgrading != null)
        _upgradeDetails(details, enabled: enabled)
      else if (!details.supported)
        TdPanel(
          title: 'This version needs an unsupported configuration flow',
          child: Text(
            details.blockedReason ??
                details.formSchema.unsupportedReasons.join('\n'),
          ),
        )
      else ...[
        const Text('Application settings', style: TdTypography.titleMedium),
        const SizedBox(height: 8),
        const Text(
          'Conditional controls describe when they apply. Inactive settings are omitted. '
          'Secrets are not shown in the confirmation and are cleared after review.',
        ),
        const SizedBox(height: 16),
        AdminSchemaForm(
          key: _form,
          parameters: details.parameters,
          enabled: enabled,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!),
          ),
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('app-review-install'),
          onPressed: enabled ? () => _review(details) : null,
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(
            widget.upgrading == null ? 'Review installation' : 'Review upgrade',
          ),
        ),
      ],
    ],
  );

  Widget _upgradeDetails(AppVersionDetails details, {required bool enabled}) {
    if (!details.upgradeSupported) {
      return Text(
        details.blockedReason ?? 'This version cannot be upgraded safely.',
      );
    }
    return ref
        .watch(appUpgradeReviewProvider((widget.upgrading!, details)))
        .when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const Text(
            'The server could not confirm this upgrade. Choose another version or reload the catalog.',
          ),
          data: (review) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TdPanel(
                title: 'Upgrade to ${review.humanVersion}',
                child: Text(
                  review.changelog.isEmpty
                      ? 'No release notes supplied by the server.'
                      : review.changelog,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Existing configuration is retained by the server. Host-path snapshots are not requested. Review application-specific migration requirements before proceeding.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('app-review-upgrade'),
                onPressed: enabled
                    ? () => _review(details, upgradeReview: review)
                    : null,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Review upgrade'),
              ),
            ],
          ),
        );
  }

  Future<void> _review(
    AppVersionDetails details, {
    AppUpgradeReview? upgradeReview,
  }) async {
    final name = _name.text;
    if (name.length > 40 ||
        !RegExp(r'^[a-z]([-a-z0-9]*[a-z0-9])?$').hasMatch(name)) {
      setState(
        () => _error = 'Enter a valid application name. No request was sent.',
      );
      return;
    }
    Map<String, Object?> values = const {};
    List<String> preview = const [];
    if (widget.upgrading == null) {
      final arguments = _form.currentState?.validateAndBuild();
      if (arguments == null ||
          arguments.length != 1 ||
          arguments.single is! Map) {
        return;
      }
      final raw = Map<String, Object?>.from(arguments.single as Map);
      final error = details.formSchema.validate(raw);
      if (error != null) {
        setState(() => _error = error);
        return;
      }
      try {
        values = details.formSchema.buildValues(raw);
        preview = appSettingsReviewLines(details.formSchema.previewValues(raw));
      } on FormatException {
        setState(
          () => _error =
              'The settings cannot be reviewed safely. No request was sent.',
        );
        return;
      }
    } else if (upgradeReview == null) {
      return;
    }
    setState(() {
      _reviewing = true;
      _error = null;
    });
    bool confirmed = false;
    try {
      confirmed = await confirmAppOperation(
        context,
        title: widget.upgrading == null
            ? 'Confirm installation'
            : 'Confirm upgrade',
        endpoint: widget.session.endpoint!,
        target: name,
        warning:
            '${widget.app.train}/${widget.app.name} · version ${details.version}\n'
            '${widget.upgrading == null ? 'A new application will be created.' : 'The application may be stopped and recreated. Connected users may be interrupted.'}\n'
            '${widget.upgrading == null ? 'The settings below will be submitted. Secret values are hidden.' : 'Existing configuration is preserved and migrated by the server. No configuration overrides will be sent.'} '
            'Host-path snapshots are not requested. No action is automatically retried.',
        reviewLines: preview,
      );
    } finally {
      _form.currentState?.clearSensitiveValues();
      if (mounted) setState(() => _reviewing = false);
    }
    if (!confirmed ||
        !mounted ||
        !identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    if (widget.upgrading == null) {
      await ref
          .read(appsControllerProvider.notifier)
          .install(
            widget.session,
            AppInstallRequest(details: details, appName: name, values: values),
          );
    } else {
      await ref
          .read(appsControllerProvider.notifier)
          .upgrade(
            widget.session,
            AppUpgradeRequest(
              app: widget.upgrading!,
              details: details,
              review: upgradeReview,
            ),
          );
    }
  }
}

/// Review every prepared leaf or reject the form. Never silently truncate a
/// security-relevant port, host path, or capability setting.
List<String> appSettingsReviewLines(Object? sanitized) {
  final lines = <String>[];
  var characters = 0;
  void visit(Object? value, String path) {
    if (value is Map && value.isNotEmpty) {
      for (final entry in value.entries) {
        visit(
          entry.value,
          path.isEmpty ? '${entry.key}' : '$path.${entry.key}',
        );
      }
    } else if (value is List && value.isNotEmpty) {
      for (var i = 0; i < value.length; i++) {
        visit(value[i], '$path[$i]');
      }
    } else {
      final line = '${path.isEmpty ? 'values' : path}: $value';
      characters += line.length;
      if (lines.length >= 200 || characters > 16000) {
        throw const FormatException('Settings exceed review limits.');
      }
      lines.add(line);
    }
  }

  visit(sanitized, '');
  return List.unmodifiable(lines);
}
