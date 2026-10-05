import 'package:flutter/material.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

class DesignSystemGallery extends StatefulWidget {
  const DesignSystemGallery({super.key});

  @override
  State<DesignSystemGallery> createState() => _DesignSystemGalleryState();
}

class _DesignSystemGalleryState extends State<DesignSystemGallery> {
  final _server = TextEditingController(text: 'https://nas.example');
  final _apiKey = TextEditingController();
  final _disabled = TextEditingController(text: 'Read-only preview');
  var _dark = false;
  var _showApiKey = false;

  @override
  void dispose() {
    _server.dispose();
    _apiKey.dispose();
    _disabled.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: TrueNavoTheme.light(),
    darkTheme: TrueNavoTheme.dark(),
    themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
    home: Builder(
      builder: (context) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final comfortable = dark ? TrueNavoTheme.dark() : TrueNavoTheme.light();
        final compact = dark
            ? TrueNavoTheme.dark(density: TrueNavoDensity.compact)
            : TrueNavoTheme.light(density: TrueNavoDensity.compact);
        return Scaffold(
          appBar: AppBar(
            title: const Text('TrueNavo design system gallery'),
            actions: [
              IconButton(
                tooltip: 'Toggle theme',
                onPressed: () => setState(() => _dark = !_dark),
                icon: const Icon(Icons.dark_mode_outlined),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(TdSpacing.pageMobile),
            children: [
              Text('Comfortable density', style: TdTypography.titleMedium),
              const SizedBox(height: TdSpacing.component),
              Theme(data: comfortable, child: _states(compact: false)),
              const SizedBox(height: TdSpacing.sectionMobile),
              Text('Compact density', style: TdTypography.titleMedium),
              const SizedBox(height: TdSpacing.component),
              Theme(data: compact, child: _states(compact: true)),
            ],
          ),
        );
      },
    ),
  );

  Widget _states({required bool compact}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TdPanel(
        title: 'Buttons',
        child: Wrap(
          spacing: TdSpacing.inline,
          runSpacing: TdSpacing.inline,
          children: [
            TdButton(
              label: 'Primary',
              onPressed: _noop,
              size: compact ? TdButtonSize.compact : TdButtonSize.comfortable,
            ),
            TdButton(
              label: 'Secondary',
              onPressed: _noop,
              variant: TdButtonVariant.secondary,
              size: compact ? TdButtonSize.compact : TdButtonSize.comfortable,
            ),
            TdButton(
              label: 'Ghost',
              onPressed: _noop,
              variant: TdButtonVariant.ghost,
              size: compact ? TdButtonSize.compact : TdButtonSize.comfortable,
            ),
            TdButton(
              label: 'Danger',
              onPressed: _noop,
              variant: TdButtonVariant.danger,
              size: compact ? TdButtonSize.compact : TdButtonSize.comfortable,
            ),
            TdButton(
              label: 'Loading',
              onPressed: _noop,
              isLoading: true,
              size: compact ? TdButtonSize.compact : TdButtonSize.comfortable,
            ),
            TdButton(
              label: 'Disabled',
              onPressed: null,
              size: compact ? TdButtonSize.compact : TdButtonSize.comfortable,
            ),
          ],
        ),
      ),
      const SizedBox(height: TdSpacing.group),
      const TdPanel(
        title: 'Status',
        child: Wrap(
          spacing: TdSpacing.inline,
          runSpacing: TdSpacing.inline,
          children: [
            TdStatusBadge(status: TdStatus.neutral, label: 'Neutral'),
            TdStatusBadge(status: TdStatus.success, label: 'Success'),
            TdStatusBadge(status: TdStatus.warning, label: 'Warning'),
            TdStatusBadge(status: TdStatus.critical, label: 'Critical'),
            TdStatusBadge(status: TdStatus.info, label: 'Info'),
            TdStatusBadge(status: TdStatus.stale, label: 'Stale'),
          ],
        ),
      ),
      const SizedBox(height: TdSpacing.group),
      TdPanel(
        title: 'Field states',
        child: Column(
          children: [
            TdTextField(
              label: 'Server URL',
              controller: _server,
              hintText: 'https://nas.example',
              prefixIcon: Icons.link,
              helperText: 'Use a secure HTTPS or WSS endpoint.',
            ),
            const SizedBox(height: TdSpacing.component),
            TdTextField(
              label: 'API key',
              controller: _apiKey,
              secret: true,
              obscureText: !_showApiKey,
              onToggleSecret: () => setState(() => _showApiKey = !_showApiKey),
              errorText: 'Example validation message.',
            ),
            const SizedBox(height: TdSpacing.component),
            TdTextField(
              label: 'Disabled field',
              controller: _disabled,
              enabled: false,
            ),
          ],
        ),
      ),
      const SizedBox(height: TdSpacing.group),
      const TdMetricCard(
        label: 'Pool capacity',
        value: '12.4',
        unit: 'TB',
        trend: 'Up 3%',
        freshness: 'Updated now',
      ),
      const SizedBox(height: TdSpacing.group),
      const TdStateView(
        kind: TdStateKind.loading,
        title: 'Loading state',
        description: 'Retrieving the latest resource status.',
        compact: true,
      ),
      const SizedBox(height: TdSpacing.component),
      const TdStateView(
        kind: TdStateKind.error,
        title: 'Error state',
        description: 'A safe error description.',
        actionLabel: 'Retry',
        onAction: _noop,
      ),
      const SizedBox(height: TdSpacing.component),
      const TdStateView(
        kind: TdStateKind.empty,
        title: 'Empty state',
        description: 'No resources match this view.',
      ),
    ],
  );
}

void _noop() {}
