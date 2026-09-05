import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

import 'connection_controller.dart';
import 'connection_state.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});
  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _url = TextEditingController();
  final _apiKey = TextEditingController();
  bool _showKey = false;

  @override
  void dispose() {
    _url.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(connectionControllerProvider);
    final busy = state is ConnectionInProgress;
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
                    .connect(serverInput: _url.text, apiKey: _apiKey.text),
        ),
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
          'Connect directly to a secure HTTPS or WSS endpoint. Your API key is used only for this connection attempt and is never stored or shown in the result.',
          style: TdTypography.bodyLarge.copyWith(color: td.textSecondary),
        ),
      ],
    );
  }
}
