#!/usr/bin/env bash
set -euo pipefail

# Keep Drift's committed runtime output and migration contract in lockstep.
if command -v dart >/dev/null 2>&1; then
  dart_command=(dart)
elif command -v fvm >/dev/null 2>&1; then
  dart_command=(fvm dart)
else
  printf 'Dart SDK not found.\n' >&2
  exit 127
fi

"${dart_command[@]}" run build_runner build --delete-conflicting-outputs
"${dart_command[@]}" run drift_dev schema dump \
  lib/features/local_persistence/app_database.dart \
  test/drift/schema_v1.json

schema_stage=$(mktemp -d)
trap 'rm -rf "$schema_stage"' EXIT
cp test/drift/schema_v1.json "$schema_stage/drift_schema_v1.json"
"${dart_command[@]}" run drift_dev schema generate \
  "$schema_stage" test/drift/generated

repository_root=$(git rev-parse --show-toplevel)
generated_paths=(
  apps/trueraid/lib/features/local_persistence/app_database.g.dart
  apps/trueraid/test/drift/schema_v1.json
  apps/trueraid/test/drift/generated
)
git -C "$repository_root" diff --exit-code -- "${generated_paths[@]}"
test -z "$(git -C "$repository_root" status --porcelain --untracked-files=all -- "${generated_paths[@]}")"
