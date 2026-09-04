import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                elevation: 0,
                color: const Color(0xff151c31),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          CircleAvatar(child: Icon(Icons.storage_rounded)),
                          SizedBox(width: 12),
                          Text(
                            'TrueDash',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Unofficial · planning-era M0 connection check',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        key: const Key('server-url-field'),
                        controller: _url,
                        keyboardType: TextInputType.url,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'Server URL',
                          hintText: 'https://nas.example:8443',
                          prefixIcon: Icon(Icons.link),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('api-key-field'),
                        controller: _apiKey,
                        obscureText: !_showKey,
                        enableSuggestions: false,
                        autocorrect: false,
                        enabled: !busy,
                        decoration: InputDecoration(
                          labelText: 'API key',
                          prefixIcon: const Icon(Icons.key_outlined),
                          suffixIcon: IconButton(
                            tooltip: _showKey ? 'Hide API key' : 'Show API key',
                            onPressed: () =>
                                setState(() => _showKey = !_showKey),
                            icon: Icon(
                              _showKey
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const Key('connect-button'),
                          onPressed: busy
                              ? null
                              : () => ref
                                    .read(connectionControllerProvider.notifier)
                                    .connect(
                                      serverInput: _url.text,
                                      apiKey: _apiKey.text,
                                    ),
                          icon: busy
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.lock_open_rounded),
                          label: Text(
                            busy ? 'Connecting securely…' : 'Connect',
                          ),
                        ),
                      ),
                      if (state case ConnectionFailed(:final message)) ...[
                        const SizedBox(height: 20),
                        _MessageCard(
                          icon: Icons.error_outline,
                          message: message,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ],
                      if (state case ConnectionSucceeded(:final summary)) ...[
                        const SizedBox(height: 20),
                        _SummaryCard(
                          rows: {
                            'Original host': summary.originalHostInput,
                            'Secure endpoint': summary.endpointUri.toString(),
                            'Identity': summary.identity,
                            'Version': summary.version,
                            'Methods': '${summary.availableMethodNames.length}',
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.icon,
    required this.message,
    required this.color,
  });
  final IconData icon;
  final String message;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
      ],
    ),
  );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.rows});
  final Map<String, String> rows;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xff203557),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Connected', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        for (final row in rows.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              '${row.key}: ${row.value}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    ),
  );
}
