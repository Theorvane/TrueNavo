#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == xcodebuild ]]; then
  shift
  for argument in "$@"; do
    if [[ "$argument" == -configuration ]]; then
      exec /usr/bin/xcrun xcodebuild \
        -derivedDataPath "${TRUERAID_IOS_TEST_DERIVED_DATA:?}" \
        "$@"
    fi
  done
  exec /usr/bin/xcrun xcodebuild "$@"
fi

exec /usr/bin/xcrun "$@"
