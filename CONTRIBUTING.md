# Contributing

Open feature, fix, documentation, and CI pull requests against `dev`, the integration and default branch. Its required `check` runs formatting, generated-code verification, static analysis, all package tests, and the web release build. A separate reviewer must approve the latest changes. Merge feature work with squash.

`main` is the release branch. Only a pull request from this repository's `dev` branch may promote to `main`; the `release-promotion` check rejects other sources. Use a merge commit for promotions so the dev history is preserved. Both branches reject force pushes and deletion, with no configured bypass.

Ready-for-review PRs automatically request `sjungwon03-ai` through [CODEOWNERS](.github/CODEOWNERS) and the metadata triage workflow. Drafts and PRs authored by that account are not self-requested. Requesting a review does not submit an approval, remove the separate-reviewer requirement, or merge a PR. CODEOWNERS/PR automation uses the base branch; issue automation becomes active on the default `dev` branch after merge, and `main` PR automation after its first promotion. The initial setup PR receives a one-time explicit reviewer request.

[Issue/PR triage](.github/workflows/triage.yml) adds labels from [the policy](.github/triage-labels.json): issue-form change type/area, explicit title prefixes such as `feat:`, `fix:`, `docs:`, `ci:` or `[버그]`, and PR changed/renamed paths. New/reopened issues receive `needs:triage`. Valid repository `dev` → `main` PRs receive `release:promotion`. Labeling is additive and preserves manual labels; maintainers remove stale labels or `needs:triage` after assessment. Existing repository labels are not overwritten. Automation reads issue/PR text only as data and never checks out or executes PR head code with its write token; it has no release secrets and no approval/merge capability.

For a release, increase both the semantic version and build number in `apps/truenavo/pubspec.yaml`, and add the matching English and Korean release notes. A new version promoted to `main` runs the release pipeline. An already-tagged version is skipped. See [RELEASING.md](RELEASING.md) for store setup and first-release requirements.

Keep credentials, signing keys, and appliance data out of issues, pull requests, and commits. Management tests use synthetic transports. A real appliance write needs an explicitly authorized test plan. Explain compatibility and migration effects in the pull request, and update the affected API contracts or parity ledger.
