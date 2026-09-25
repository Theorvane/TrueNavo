import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import 'secure_credential_vault.dart';

/// Shared credential boundary for connection and saved-profile actions.
final credentialVaultProvider = Provider<CredentialVault>(
  (ref) => createSecureCredentialVault(),
);
