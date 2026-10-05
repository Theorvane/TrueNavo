# Releasing TrueNavo

The branch flow follows [LabFox](https://github.com/Theorvane/LabFox): feature PR → `dev` → promotion PR → `main`. `dev` is the default integration branch; `main` is for releases. Feature PRs use squash, and release promotions use a merge commit. CI and another reviewer's approval are required.

## Release destinations

`release.yml` runs on a push to `main`. It reads `apps/truenavo/pubspec.yaml`, validates the matching English and Korean notes, and skips an already-tagged semantic version. A new release reruns the full `check` before packaging or uploading.

Until store registration and credentials are ready, `STORE_DEPLOYMENT_ENABLED=false` sends new versions to GitHub only. After configuring both stores, set that repository variable to `true`: the pipeline builds Windows/web, uploads iOS to App Store Connect, uploads Android to Play internal testing, then publishes GitHub. Store uploads do not submit an App Store review or promote Play production.

The workflow can also be run manually **on `main`** with `destination=github`, `stores`, or `all`. A stores-only upload can use a newer build number of an existing semantic version. Never repeat an accepted or uncertain store upload automatically: inspect the store first, rerun only a failed job where appropriate, or increase the build number.

Automatic GitHub releases are previews while the app remains pre-1.0. Manual dispatch permits changing the preview flag. Published versions are immutable; bump the semantic version for another GitHub release.

## How to release

1. Increase `version:` in `apps/truenavo/pubspec.yaml`, for example `0.1.1+2`. The semantic version becomes `v0.1.1`; the number after `+` is Android's versionCode and Apple's build. Both stores require a new build number.
2. Add `## 0.1.1` sections to `docs/store/release-notes.md` and `release-notes.ko.md`. Each locale must be nonempty and at most 500 characters.
3. Merge the change into `dev` after CI and review.
4. Open and approve the repository-owned `dev → main` promotion, then merge it with a merge commit. The new version releases automatically.

For the first release, finish the setup below before enabling store deployment. See [store setup](docs/store/store-setup.md) for app registration and listing requirements.

## GitHub assets

GitHub publishes the Windows x64 installer, a portable Windows ZIP, a web ZIP, and `SHA256SUMS.txt`. Windows binaries are currently unsigned. Releases disclose the SmartScreen warning; obtain a Windows signing certificate before claiming signed distribution. The web archive needs HTTPS hosting.

Release packaging uses pinned Action commit SHAs. Store environments allow deployments only from `main`. Pull-request builds never receive store credentials.

## Credentials

Register secrets in the named **TrueNavo** repository environments. GitHub does not allow reading back LabFox secrets. An Apple distribution certificate may belong to the same developer team, but the provisioning profile must specifically match `com.truenavo.truenavo`; do not reuse LabFox's profile.

| Environment | Secret | Required material |
|---|---|---|
| `play-store` | `ANDROID_KEYSTORE_BASE64` | TrueNavo upload keystore, base64-encoded |
| `play-store` | `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `play-store` | `ANDROID_KEY_ALIAS` | Upload-key alias |
| `play-store` | `ANDROID_KEY_PASSWORD` | Upload-key password |
| `play-store` | `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Service-account JSON authorized for the TrueNavo Play app |
| `app-store` | `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | Apple Distribution certificate plus private key, exported as `.p12` and base64-encoded |
| `app-store` | `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | `.p12` password |
| `app-store` | `APP_STORE_PROVISIONING_PROFILE_BASE64` | App Store distribution `.mobileprovision` for TrueNavo, base64-encoded |
| `app-store` | `ASC_KEY_ID` | App Store Connect API key ID |
| `app-store` | `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `app-store` | `ASC_PRIVATE_KEY` | Contents of the API `.p8` key |

`APPLE_TEAM_ID` is a variable in `app-store`. `STORE_DEPLOYMENT_ENABLED` is a repository variable; leave it `false` until both app registrations and credentials are ready. The `github-release` environment needs no added secret: its job uses the scoped GitHub Actions token.

Use `python3 scripts/configure_release.py android ...` or `apple ...` to upload local files securely. Passwords are prompted without echo, and values go to `gh secret set` over stdin. `python3 scripts/configure_release.py check` lists missing setting names without printing values. Keep separate backups of signing keys.

```sh
python3 scripts/configure_release.py android --keystore /secure/truenavo-upload.jks --alias upload --service-account /secure/play-service-account.json
python3 scripts/configure_release.py apple --p12 /secure/distribution.p12 --profile /secure/truenavo.mobileprovision --p8 /secure/AuthKey.p8 --team TEAMID1234 --key-id KEYID12345 --issuer 12345678-1234-1234-1234-123456789abc
python3 scripts/configure_release.py check
```

## Local Android release signing

Release builds require a real key and never fall back to debug signing. CI uses `TRUENAVO_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`. Locally you may instead use the gitignored `apps/truenavo/android/key.properties` with `storeFile`, `storePassword`, `keyAlias`, and `keyPassword`. Keep `storeFile` absolute.

Build the first signed bundle with `flutter build appbundle --release` in `apps/truenavo` and upload it in Play Console to initialize the app before API releases. For iOS, register the bundle ID and App Store Connect app before uploading. App Store signing validates the team, exact bundle ID, expiry, distribution profile type, and exported IPA version.

## External prerequisites

Store upload automation is implemented, but it is not proof that an upload or a public store release has occurred. Account agreements, app registration, listing images, privacy declarations, review access, export compliance, and store review remain required. The app still has partial TrueNAS parity and no real-appliance write acceptance; the listing and release notes say so.
