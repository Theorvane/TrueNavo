"""Register TrueNavo release secrets from local files; never print their values."""

import argparse
import base64
import getpass
import json
from pathlib import Path
import re
import subprocess


REPO = "Theorvane/TrueNavo"
REQUIRED = {
    "play-store": ["ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS",
                   "ANDROID_KEY_PASSWORD", "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"],
    "app-store": ["APPLE_DISTRIBUTION_CERTIFICATE_BASE64", "APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD",
                  "APP_STORE_PROVISIONING_PROFILE_BASE64", "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY"],
}


def secret(environment, name, value):
    if not value:
        raise ValueError(f"Missing value for {name}")
    subprocess.run(["gh", "secret", "set", name, "--repo", REPO, "--env", environment], input=value, check=True)
    print(f"Configured {environment}/{name}")


def api(path):
    result = subprocess.run(["gh", "api", path], check=True, capture_output=True)
    return json.loads(result.stdout)


def check():
    missing = []
    for environment, names in REQUIRED.items():
        settings = api(f"repos/{REPO}/environments/{environment}/secrets")
        available = {entry["name"] for entry in settings["secrets"]}
        missing.extend(f"{environment}/{name}" for name in names if name not in available)
    settings = api(f"repos/{REPO}/environments/app-store/variables")
    if "APPLE_TEAM_ID" not in {entry["name"] for entry in settings["variables"]}:
        missing.append("app-store/APPLE_TEAM_ID")
    for name in missing:
        print(f"Missing: {name}")
    print("All credential names are configured" if not missing else "Store deployment is not configured yet")
    return 0 if not missing else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    android = commands.add_parser("android")
    android.add_argument("--keystore", type=Path, required=True)
    android.add_argument("--service-account", type=Path, required=True)
    android.add_argument("--alias", required=True)
    apple = commands.add_parser("apple")
    apple.add_argument("--p12", type=Path, required=True)
    apple.add_argument("--profile", type=Path, required=True)
    apple.add_argument("--p8", type=Path, required=True)
    apple.add_argument("--team", required=True)
    apple.add_argument("--key-id", required=True)
    apple.add_argument("--issuer", required=True)
    commands.add_parser("check")
    args = parser.parse_args()
    if args.command == "check":
        return check()
    if args.command == "android":
        service_account = args.service_account.read_bytes()
        account = json.loads(service_account)
        if not isinstance(account, dict) or account.get("type") != "service_account":
            raise ValueError("Google Play credential must be a service-account JSON")
        keystore = args.keystore.read_bytes()
        store_password = getpass.getpass("Keystore password: ").encode()
        key_password = getpass.getpass("Upload-key password: ").encode()
        values = {
            "ANDROID_KEYSTORE_BASE64": base64.b64encode(keystore),
            "ANDROID_KEYSTORE_PASSWORD": store_password,
            "ANDROID_KEY_ALIAS": args.alias.encode(),
            "ANDROID_KEY_PASSWORD": key_password,
            "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON": service_account,
        }
        environment = "play-store"
    else:
        if not re.fullmatch(r"[A-Za-z0-9]{10}", args.team) or not re.fullmatch(r"[A-Za-z0-9]{10}", args.key_id):
            raise ValueError("Invalid Apple team/key ID")
        if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", args.issuer):
            raise ValueError("Invalid App Store Connect issuer ID")
        private_key = args.p8.read_bytes()
        if b"-----BEGIN PRIVATE KEY-----" not in private_key:
            raise ValueError("Expected an App Store Connect API .p8 private key")
        certificate, profile = args.p12.read_bytes(), args.profile.read_bytes()
        password = getpass.getpass("Apple Distribution .p12 password: ").encode()
        values = {
            "APPLE_DISTRIBUTION_CERTIFICATE_BASE64": base64.b64encode(certificate),
            "APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD": password,
            "APP_STORE_PROVISIONING_PROFILE_BASE64": base64.b64encode(profile),
            "ASC_KEY_ID": args.key_id.encode(), "ASC_ISSUER_ID": args.issuer.encode(),
            "ASC_PRIVATE_KEY": private_key,
        }
        environment = "app-store"
    if not all(values.values()):
        raise ValueError("All required credential values must be supplied before configuring an environment")
    for name, value in values.items():
        secret(environment, name, value)
    if args.command == "apple":
        subprocess.run(["gh", "variable", "set", "APPLE_TEAM_ID", "--repo", REPO,
                        "--env", environment, "--body", args.team], check=True)
    print("Credentials registered. Finish console setup before enabling STORE_DEPLOYMENT_ENABLED.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.CalledProcessError):
        raise SystemExit("Release configuration failed; check files, account permissions, and required values. Secret values were not printed.")
