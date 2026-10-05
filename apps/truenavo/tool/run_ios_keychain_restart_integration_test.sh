#!/usr/bin/env bash
# Runs the two process invocations required to prove iOS Keychain persistence.
set -euo pipefail
IFS=$'\n\t'

readonly bundle_id='com.truenavo.truenavo'
readonly test_file='integration_test/ios_keychain_restart_test.dart'
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly app_dir="$(cd -- "$script_dir/.." && pwd -P)"
readonly xcrun_shim_source="$script_dir/xcrun_with_derived_data.sh"

derived_data_path="$(mktemp -d "${TMPDIR:-/tmp}/truenavo-ios-keychain-derived.XXXXXX")"
xcrun_shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/truenavo-xcrun-shim.XXXXXX")"
ln -s -- "$xcrun_shim_source" "$xcrun_shim_dir/xcrun"

device_udid=''
created_simulator=false

cleanup() {
  local status=$?
  if [[ "$created_simulator" == true && -n "$device_udid" ]]; then
    # This UDID was created by this invocation; no shared simulator is touched.
    xcrun simctl terminate "$device_udid" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$device_udid" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$device_udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$device_udid" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$derived_data_path" "$xcrun_shim_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

command -v xcrun >/dev/null || {
  echo 'xcrun is required to run the iOS Keychain integration test.' >&2
  exit 1
}
command -v fvm >/dev/null || {
  echo 'fvm is required to run the workspace-pinned Flutter SDK.' >&2
  exit 1
}

selection="$(xcrun simctl list devices available -j | python3 -c '
import json
import sys

def runtime_version(identifier):
    return tuple(int(part) for part in identifier.rsplit("iOS-", 1)[1].split("-"))

candidates = [
    (runtime_version(runtime), device["deviceTypeIdentifier"], runtime)
    for runtime, devices in json.load(sys.stdin).get("devices", {}).items()
    if runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
    for device in devices
    if device.get("isAvailable", False) and device.get("deviceTypeIdentifier")
]
if not candidates:
    raise SystemExit("No available compatible iOS simulator device type/runtime.")
_, device_type, runtime = max(candidates)
print("{}\t{}".format(device_type, runtime))
')" || {
  echo 'Unable to select a compatible iOS simulator runtime and device type.' >&2
  exit 1
}
IFS=$'\t' read -r device_type runtime <<<"$selection"
IFS=$'\n\t'

simulator_name="truenavo-tls-pin-${$}-${RANDOM}"
device_udid="$(xcrun simctl create "$simulator_name" "$device_type" "$runtime")"
created_simulator=true
echo "Created isolated iOS simulator: $simulator_name ($device_udid)"
xcrun simctl boot "$device_udid"
xcrun simctl bootstatus "$device_udid" -b

cd -- "$app_dir"
PATH="$xcrun_shim_dir:$PATH" \
TRUENAVO_IOS_TEST_DERIVED_DATA="$derived_data_path" \
fvm flutter test "$test_file" -d "$device_udid" \
  --dart-define=keychainTestPhase=write
PATH="$xcrun_shim_dir:$PATH" \
TRUENAVO_IOS_TEST_DERIVED_DATA="$derived_data_path" \
fvm flutter test "$test_file" -d "$device_udid" \
  --dart-define=keychainTestPhase=read-delete
