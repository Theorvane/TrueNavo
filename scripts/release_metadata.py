"""Validate release versions and extract reviewed store notes; stdlib only."""

import argparse
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
LOCALES = {"en-US": "release-notes.md", "ko-KR": "release-notes.ko.md"}


def read_metadata(source):
    matches = re.findall(r"^version:\s*(\S+)\s*$", source, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError("Expected exactly one version in app pubspec")
    match = re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+([1-9]\d*)", matches[0])
    if not match:
        raise ValueError("Release version must be MAJOR.MINOR.PATCH+positiveBuildNumber")
    version, build = matches[0].split("+")
    if int(build) > 2_100_000_000:
        raise ValueError("Android versionCode exceeds its supported limit")
    return {"version": version, "build": build, "tag": f"v{version}"}


def extract_notes(source, version):
    match = re.search(rf"^## {re.escape(version)}\s*$\n(.*?)(?=^## |\Z)", source, re.MULTILINE | re.DOTALL)
    if not match or not match.group(1).strip():
        raise ValueError(f"Missing release notes for {version}")
    text = match.group(1).strip()
    if len(text) > 500:
        raise ValueError("Store release notes exceed 500 characters")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--whatsnew", type=Path)
    parser.add_argument("--github-notes", type=Path)
    args = parser.parse_args()
    metadata = read_metadata((ROOT / "apps/truenavo/pubspec.yaml").read_text())
    notes = {
        locale: extract_notes((ROOT / "docs/store" / filename).read_text(), metadata["version"])
        for locale, filename in LOCALES.items()
    }
    if args.github_output:
        with args.github_output.open("a") as output:
            for key, value in metadata.items():
                output.write(f"{key}={value}\n")
    if args.whatsnew:
        args.whatsnew.mkdir(parents=True, exist_ok=True)
        for locale, text in notes.items():
            (args.whatsnew / f"whatsnew-{locale}").write_text(text + "\n")
    if args.github_notes:
        args.github_notes.write_text(
            f"## TrueNavo {metadata['version']}\n\n{notes['en-US']}\n\n"
            "Windows downloads include an installer and a portable ZIP. They are unsigned; "
            "Windows may show a SmartScreen warning. Verify SHA256SUMS.txt against your download.\n\n"
            "The web ZIP is a static build. Serve it over HTTPS; it is not an installed mobile app. "
            "Android and iOS distribution is handled separately through their stores.\n"
        )
    print(json.dumps(metadata))


if __name__ == "__main__":
    main()
