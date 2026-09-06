#!/usr/bin/env bash
# Runs the two process invocations required to prove iOS Keychain persistence.
set -euo pipefail
IFS=$'\n\t'

readonly bundle_id='com.truedash.truedash'
readonly test_file='integration_test/ios_keychain_restart_test.dart'
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly app_dir="$(cd -- "$script_dir/.." && pwd -P)"
readonly xcrun_shim_source="$script_dir/xcrun_with_derived_data.sh"

derived_data_path="$(mktemp -d "${TMPDIR:-/tmp}/truedash-ios-keychain-derived.XXXXXX")"
xcrun_shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/truedash-xcrun-shim.XXXXXX")"
ln -s -- "$xcrun_shim_source" "$xcrun_shim_dir/xcrun"

device_udid=''
booted_by_script=false

cleanup() {
  local status=$?
  if [[ -n "$device_udid" ]]; then
    xcrun simctl terminate "$device_udid" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$device_udid" "$bundle_id" >/dev/null 2>&1 || true
    if [[ "$booted_by_script" == true ]]; then
      xcrun simctl shutdown "$device_udid" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf -- "$derived_data_path" "$xcrun_shim_dir"
  exit "$status"
}
trap cleanup EXIT

command -v xcrun >/dev/null || {
  echo 'xcrun is required to run the iOS Keychain integration test.' >&2
  exit 1
}
command -v fvm >/dev/null || {
  echo 'fvm is required to run the workspace-pinned Flutter SDK.' >&2
  exit 1
}

device_selection="$({ xcrun simctl list devices available -j; } | python3 -c '
import json
import sys

devices = [
    device
    for runtime, runtime_devices in json.load(sys.stdin).get("devices", {}).items()
    if runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
    for device in runtime_devices
    if device.get("isAvailable", False)
]
booted = [device for device in devices if device.get("state") == "Booted"]
shutdown = [device for device in devices if device.get("state") == "Shutdown"]
selected = sorted(booted or shutdown, key=lambda device: (device["name"], device["udid"]))
if not selected:
    raise SystemExit("No available iOS simulator is Booted or Shutdown.")
device = selected[0]
print("{}\t{}\t{}".format(device["udid"], device["state"], device["name"]))
')" || {
  echo 'Unable to select an available iOS simulator.' >&2
  exit 1
}
IFS=$'\t' read -r device_udid device_state device_name <<<"$device_selection"
IFS=$'\n\t'

echo "Using iOS simulator: $device_name ($device_udid; $device_state)"
if [[ "$device_state" == 'Shutdown' ]]; then
  xcrun simctl boot "$device_udid"
  booted_by_script=true
fi
xcrun simctl bootstatus "$device_udid" -b

cd -- "$app_dir"
# The write phase deletes this dedicated test-only Keychain key before writing.
# Uninstalling here clears the app container without touching any simulator.
xcrun simctl terminate "$device_udid" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl uninstall "$device_udid" "$bundle_id" >/dev/null 2>&1 || true

PATH="$xcrun_shim_dir:$PATH" \
TRUEDASH_IOS_TEST_DERIVED_DATA="$derived_data_path" \
fvm flutter test "$test_file" -d "$device_udid" \
  --dart-define=keychainTestPhase=write
PATH="$xcrun_shim_dir:$PATH" \
TRUEDASH_IOS_TEST_DERIVED_DATA="$derived_data_path" \
fvm flutter test "$test_file" -d "$device_udid" \
  --dart-define=keychainTestPhase=read-delete
