#!/usr/bin/env bash
set -euo pipefail

aab_path="${1:?Pass the signed AAB path}"
test -n "${TRUENAVO_KEYSTORE_PATH:?}"
test -n "${ANDROID_KEYSTORE_PASSWORD:?}"
test -n "${ANDROID_KEY_ALIAS:?}"
jarsigner -verify "$aab_path"
expected_fingerprint="$(keytool -J-Duser.language=en -list -v -keystore "$TRUENAVO_KEYSTORE_PATH" -storepass:env ANDROID_KEYSTORE_PASSWORD -alias "$ANDROID_KEY_ALIAS" | sed -n 's/.*SHA256: //p' | sed -n '1p')"
actual_certificate="$(keytool -J-Duser.language=en -printcert -jarfile "$aab_path")"
actual_fingerprint="$(printf '%s\n' "$actual_certificate" | sed -n 's/.*SHA256: //p' | sed -n '1p')"
test -n "$expected_fingerprint"
test "$expected_fingerprint" = "$actual_fingerprint"
case "$actual_certificate" in
  *'CN=Android Debug'*)
    echo '::error::Debug signing is not accepted for store deployment.'
    exit 1
    ;;
esac
