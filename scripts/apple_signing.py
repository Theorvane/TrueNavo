"""Validate App Store signing metadata without printing certificate or key data."""

import argparse
import datetime
import os
from pathlib import Path
import plistlib
import re
import zipfile


def validate_profile(profile, team, bundle, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    entitlements = profile.get("Entitlements", {})
    if not team or not bundle or team not in profile.get("TeamIdentifier", []):
        raise ValueError("Provisioning profile has the wrong Apple team")
    if entitlements.get("application-identifier") != f"{team}.{bundle}":
        raise ValueError("Provisioning profile must explicitly match the TrueNavo bundle ID")
    if entitlements.get("com.apple.developer.team-identifier") != team:
        raise ValueError("Provisioning entitlement has the wrong Apple team")
    if entitlements.get("get-task-allow") is not False:
        raise ValueError("A distribution provisioning profile is required")
    if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices"):
        raise ValueError("An App Store profile is required, not development/ad hoc/enterprise")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime) or expiry <= now:
        raise ValueError("Provisioning profile is expired or has no valid expiration")
    name, uuid = profile.get("Name"), profile.get("UUID")
    if not isinstance(name, str) or not name or "\n" in name or "\r" in name:
        raise ValueError("Invalid provisioning profile name")
    if not isinstance(uuid, str) or not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", uuid):
        raise ValueError("Invalid provisioning profile UUID")
    return name, uuid


def export_options(team, bundle, name):
    return {
        "destination": "export", "method": "app-store-connect",
        "teamID": team, "signingStyle": "manual",
        "provisioningProfiles": {bundle: name},
        "manageAppVersionAndBuildNumber": False,
        "uploadSymbols": True,
    }


def validate_ipa(path, bundle, version, build):
    with zipfile.ZipFile(path) as archive:
        infos = [entry for entry in archive.namelist()
                 if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", entry)]
        if len(infos) != 1:
            raise ValueError("Expected exactly one application in the exported IPA")
        info = plistlib.loads(archive.read(infos[0]))
    if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"),
            str(info.get("CFBundleVersion"))) != (bundle, version, build):
        raise ValueError("Exported IPA identity/version does not match the release")
    if "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("A physical-device iOS build is required")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["profile", "ipa"])
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    team, bundle = os.environ.get("APPLE_TEAM_ID"), os.environ["BUNDLE_ID"]
    if args.mode == "profile":
        with args.path.open("rb") as source:
            name, uuid = validate_profile(plistlib.load(source), team, bundle)
        with Path(os.environ["GITHUB_ENV"]).open("a") as output:
            output.write(f"PROFILE_NAME={name}\nPROFILE_UUID={uuid}\n")
        with (Path(os.environ["RUNNER_TEMP"]) / "ExportOptions.plist").open("wb") as output:
            plistlib.dump(export_options(team, bundle, name), output)
    else:
        validate_ipa(args.path, bundle, os.environ["RELEASE_VERSION"], os.environ["RELEASE_BUILD"])
    print("Apple release metadata validated")


if __name__ == "__main__":
    main()
