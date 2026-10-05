# TrueNavo store setup

The app display name is **TrueNavo**; the listing title is **TrueNavo For TrueNas**. Both Android and iOS use `com.truenavo.truenavo`. These registrations are separate from the former TrueRAID/TrueDash identifiers.

## Google Play

Create the TrueNavo app in Play Console, enroll in Play App Signing, and make the first signed AAB upload to internal testing in the console. Grant the service account access to this app and permission to manage internal testing releases. Register its JSON and the upload-key material in the TrueNavo `play-store` environment.

The automated job uploads a signed AAB and reviewed English/Korean notes to **internal testing**. It does not promote production. A personal developer account may have additional testing/production-access requirements imposed by Play Console; follow the requirements shown for this specific account.

## Apple

Register the explicit bundle ID `com.truenavo.truenavo` in the selected Apple developer team, create its App Store Connect app record, and create an **App Store distribution** provisioning profile. The profile must not be a development, ad hoc, enterprise, wildcard, expired, or LabFox profile. Provide the distribution `.p12` with its private key, profile, and an App Store Connect API `.p8` with permission to upload this app's builds.

The automated job uploads to App Store Connect; it does not submit review, create a public App Store listing, or configure external TestFlight testing. Wait for build processing, complete export compliance and TestFlight information, select the build, and then invite testers or submit review as appropriate.

## Listing assets and declarations

Use [listing.md](listing.md) as initial copy and review it against the exact binary. Supply a TrueNavo app icon, Play's feature graphic, phone/tablet screenshots, a public privacy-policy URL, and developer/support contact details. The current launcher assets still use the Flutter placeholder and must be replaced before store submission.

The repository currently has no advertising, subscription, or analytics SDK in the app dependencies. Describe the implemented binary rather than the product plan: credentials are entered to connect to a user-chosen TrueNAS server, and inventory/management information comes from that server. Review the local-storage behavior, user-triggered exports, cloud/task operations, and installed dependencies when completing Data safety and App Privacy. Store declarations and legal policy require the developer's final review.

Provide review access that store reviewers can actually reach: an isolated demo server/account or a reviewed connector-free demonstration flow. A private LAN address and personal administrator API key are unsuitable review credentials. Do not reuse the previously supplied read-only development credential as a store-review account.

The current app has partial TrueNAS compatibility and management writes have not been accepted on a real appliance. Keep that disclosure in store copy and release notes; a green build is not a full compatibility claim.

## Needed from the maintainer

- Play app registration/initial upload status, upload `.jks`/`.keystore`, key alias and passwords, authorized service-account JSON.
- Apple developer team ID, TrueNavo bundle/app registration, distribution `.p12` and password, TrueNavo App Store `.mobileprovision`, API `.p8`, key ID, and issuer ID.
- TrueNavo icon, listing screenshots/feature graphic, public privacy-policy URL, support/developer contact, and store-review access.

Upload secrets directly to [TrueNavo environments](https://github.com/Theorvane/TrueNavo/settings/environments) or use the local configuration helper described in [RELEASING.md](../../RELEASING.md). Do not commit them or paste private keys into issues or pull requests.

Official guides: [Flutter Android deployment](https://docs.flutter.dev/deployment/android), [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios), and [GitHub deployment environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).
