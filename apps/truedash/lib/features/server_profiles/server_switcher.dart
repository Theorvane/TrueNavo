import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_profiles_controller.dart';

class ServerSwitcher extends ConsumerWidget {
  const ServerSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(serverProfilesControllerProvider);
    if (state.profiles.isEmpty) {
      return const Text('No server selected');
    }
    return Semantics(
      label: 'Choose server',
      button: true,
      child: PopupMenuButton<String>(
        tooltip: 'Choose server',
        constraints: const BoxConstraints(minWidth: 220),
        onSelected: ref.read(serverProfilesControllerProvider.notifier).select,
        itemBuilder: (context) => [
          for (final profile in state.profiles)
            PopupMenuItem(
              value: profile.id,
              child: Semantics(
                selected: profile.id == state.selectedProfileId,
                child: Text(profile.displayName),
              ),
            ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.storage_outlined),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  state.selectedProfile?.displayName ?? 'No server selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }
}
