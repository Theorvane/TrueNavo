# TrueNavo store setup

The app display name is **TrueNavo**; the listing title is **TrueNavo For TrueNas**. Both Android and iOS use `com.sloki9637.truenavo`. These registrations are separate from the former TrueRAID/TrueDash identifiers.

## Google Play

Create the TrueNavo app in Play Console, enroll in Play App Signing, and make the first signed AAB upload to internal testing in the console. Grant the service account access to this app and permission to manage internal testing releases. Register its JSON and the upload-key material in the TrueNavo `play-store` environment.

The automated job uploads a signed AAB and reviewed English/Korean notes to **internal testing**. It does not promote production. A personal developer account may have additional testing/production-access requirements imposed by Play Console; follow the requirements shown for this specific account.

## Apple

Register the explicit bundle ID `com.sloki9637.truenavo` in the selected Apple developer team, create its App Store Connect app record, and create an **App Store distribution** provisioning profile. The profile must not be a development, ad hoc, enterprise, wildcard, expired, or LabFox profile. Provide the distribution `.p12` with its private key, profile, and an App Store Connect API `.p8` with permission to upload this app's builds.

The automated job uploads to App Store Connect; it does not submit review, create a public App Store listing, or configure external TestFlight testing. Wait for build processing, complete export compliance and TestFlight information, select the build, and then invite testers or submit review as appropriate.

## Listing assets and declarations

Use [listing.md](listing.md) as initial copy and review it against the exact binary. The approved TrueNavo icon is in [brand/truenavo-icon.png](../../brand/truenavo-icon.png); committed Android, iOS, macOS, Windows and web launcher assets are generated using `dart run tool/generate_brand_icons.dart` from `apps/truenavo`. The wrapper preserves Xcode project settings during icon generation. The developer-supplied privacy-policy URL is https://www.sloki9637.com/privacy (HTTP 200 verified on 2026-10-05). Its current mobile-specific notices concern other apps; confirm that the policy accurately covers TrueNavo's local credentials and user-selected server connections before public submission. Play's feature graphic, phone/tablet screenshots and developer/support contact details still need final review.

The repository currently has no advertising, subscription, or analytics SDK in the app dependencies. Describe the implemented binary rather than the product plan: credentials are entered to connect to a user-chosen TrueNAS server, and inventory/management information comes from that server. Review the local-storage behavior, user-triggered exports, cloud/task operations, and installed dependencies when completing Data safety and App Privacy. Store declarations and legal policy require the developer's final review.

Provide review access that store reviewers can actually reach: an isolated demo server/account or a reviewed connector-free demonstration flow. A private LAN address and personal administrator API key are unsuitable review credentials. Do not reuse the previously supplied read-only development credential as a store-review account.

### Offline demonstration access (build 2 and later)

The release app has a public **Explore offline demo** button on its connection screen. It needs no NAS, credentials, network, payment, OTP or other device. It opens the normal dashboard and native management pages with synthetic sample data. A persistent banner discloses demo mode on pages and dialogs. Management forms can be explored, but submissions are rejected; this is not evidence of a successful real operation. Some workspaces remain unavailable under the app's documented partial compatibility. The demo does not guarantee store acceptance or substitute for testing real connections.

Declare the real app's NAS authentication/connection restriction accurately in Play's App access form. Describe the offline demo as an alternate demonstration route, not an unrestricted real NAS account. Use these English instructions only with a binary containing the button (the previously supplied build 1 does not):

```text
Instruction name: TrueNavo offline demonstration

Open the app and tap "Explore offline demo" on the connection screen.
No username, password, server address, API key, OTP, internet connection,
payment, or separate device is required for this demonstration.
Browse Home, Storage, Workloads, Alerts, and Jobs. Use "Manage server"
or search to explore the available management screens and sample graphs.
The banner "OFFLINE DEMO · SAMPLE DATA" identifies synthetic data.
Management submissions are blocked; they do not modify a NAS.
Tap "Exit demo" to return to the normal connection screen. Demo state
is discarded. Real monitoring and management require the user's own
compatible TrueNAS server and account; no personal NAS credentials
are provided for review.
```

Leave credential fields empty when the console allows credential-free instructions; do not invent a demo account or paste a personal administrator key. Verify the exact review binary and explain any functionality the demo does not expose. Google requires reusable, location-independent review access and English instructions: [sign-in details requirements](https://support.google.com/googleplay/android-developer/answer/15748846?hl=en).

The current app has partial TrueNAS compatibility and management writes have not been accepted on a real appliance. Keep that disclosure in store copy and release notes; a green build is not a full compatibility claim.

## Needed from the maintainer

- Play app registration/initial upload status, upload `.jks`/`.keystore`, key alias and passwords, authorized service-account JSON.
- Apple developer team ID, TrueNavo bundle/app registration, distribution `.p12` and password, TrueNavo App Store `.mobileprovision`, API `.p8`, key ID, and issuer ID.
- Listing screenshots/feature graphic, confirmation of the supplied privacy policy, support/developer contact, and store-review access.

Upload secrets directly to [TrueNavo environments](https://github.com/Theorvane/TrueNavo/settings/environments) or use the local configuration helper described in [RELEASING.md](../../RELEASING.md). Do not commit them or paste private keys into issues or pull requests.

Official guides: [Flutter Android deployment](https://docs.flutter.dev/deployment/android), [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios), and [GitHub deployment environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).
