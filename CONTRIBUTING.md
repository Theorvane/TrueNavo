# Contributing

Open feature, fix, documentation, and CI pull requests against `dev`, the integration and default branch. Its required `check` runs formatting, generated-code verification, static analysis, all package tests, and the web release build. A separate reviewer must approve the latest changes. Merge feature work with squash.

`main` is the release branch. Only a pull request from this repository's `dev` branch may promote to `main`; the `release-promotion` check rejects other sources. Use a merge commit for promotions so the dev history is preserved. Both branches reject force pushes and deletion, with no configured bypass.

For a release, increase both the semantic version and build number in `apps/truenavo/pubspec.yaml`, and add the matching English and Korean release notes. A new version promoted to `main` runs the release pipeline. An already-tagged version is skipped. See [RELEASING.md](RELEASING.md) for store setup and first-release requirements.

Keep credentials, signing keys, and appliance data out of issues, pull requests, and commits. Management tests use synthetic transports. A real appliance write needs an explicitly authorized test plan. Explain compatibility and migration effects in the pull request, and update the affected API contracts or parity ledger.
