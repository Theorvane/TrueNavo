# Dashboard and management scope

This document records the earlier dashboard/Quick management increment. The broader current target and implementation gaps are tracked in [WebUI parity status](WEBUI_PARITY_STATUS.md); full administration is no longer excluded from the product target.

This increment extends the existing read-only inventory without widening its six-method query allowlist. Mutation commands are separately typed, session-bound and version-gated. TrueNavo remains unofficial; these adapters are not appliance certification.

## Available operations

| Operation | 25.04 | 25.10 / 26.0 |
| --- | --- | --- |
| Start / stop / restart service | `service.start`, `service.stop`, `service.restart` | `service.control`, then ID-filtered `core.get_jobs` |
| Create child filesystem dataset | `pool.dataset.create` | Same |
| Delete non-root dataset | `pool.dataset.attachments` preflight, then `pool.dataset.delete` | Same |
| Create one snapshot | `zfs.snapshot.create` | `pool.snapshot.create` |

Unknown/prerelease versions stay disabled. A method's presence is not proof of write permission; a remote permission rejection is shown without exposing raw server messages. Missing inventory IDs, transformed names, ambiguous duplicates and protected paths cannot become management targets.

## Safety and limitations

- Each operation shows the original server endpoint, exact target and impact before submission. Deletion additionally requires typing the complete target, exactly.
- Changing the selected profile or live session invalidates a pending confirmation. The app prevents duplicate concurrent submissions and retains operation state when a route is closed.
- Job acceptance is not success. Polling is bounded, targets only the returned job ID and never retries a mutation. Timeout, lost connection or unverifiable results are explicitly unknown; verify Jobs and server state before resubmitting.
- Dataset creation uses inherited defaults, no automatic ancestors, shares or permissions. Snapshots are non-recursive and are not independent backups.
- Delete sends `recursive: false` and `force: false`, blocks pool roots and protected system paths, and refuses observed attached shares/tasks. **The dependency read and deletion are not atomic. Do not create or change shares/tasks concurrently: TrueNAS can remove newly attached resources between the preflight and deletion.** Files in the selected dataset are permanently removed; no undo is provided.
- No live-appliance writes are used for automated or emulator verification. A separate debug preview uses explicitly labeled sample data and cannot contact a NAS.

## Dashboard

Pool capacity charts use each pool's own reported percentage; unrelated pools are not summed or averaged. Alert proportions use complete response counts, not the bounded list displayed in inventory. Missing, invalid and zero values remain distinct. No CPU/network history is fabricated.

## Contract references

- [TrueNAS 25.10 service control](https://api.truenas.com/v25.10.0/api_methods_service.control.html)
- [TrueNAS 25.10 dataset creation](https://api.truenas.com/v25.10/api_methods_pool.dataset.create.html)
- [TrueNAS 25.10 dataset deletion](https://api.truenas.com/v25.10/api_methods_pool.dataset.delete.html)
- [TrueNAS 25.10 snapshot creation](https://api.truenas.com/v25.10/api_methods_pool.snapshot.create.html)
- [25.04.2 middleware service implementation](https://github.com/truenas/middleware/blob/TS-25.04.2/src/middlewared/middlewared/plugins/service.py)
- [25.04.2 dataset implementation](https://github.com/truenas/middleware/blob/TS-25.04.2/src/middlewared/middlewared/plugins/pool_/dataset.py)

## Local verification

From `apps/truenavo`: `fvm flutter analyze`, `fvm flutter test`, `fvm flutter build apk --debug`.
From `packages/truenas_api`: `fvm dart test`.

Use the dev-only `lib/dev/dashboard_preview_main.dart` target to inspect the interface without a server. The normal entrypoint contains no sample data. Install the normal APK after preview testing before connecting to a real server.

### Verification evidence — 2026-09-12

- Flutter application: 632 tests passed, 1 existing skip; `flutter analyze` clean.
- API package: 120 tests passed, including 56 management wire-contract tests. No analyzer errors or warnings; one existing informational lint remains.
- Android debug build passed. The sample dashboard, charts and management pages were visually inspected on the Pixel 10 Pro emulator, then replaced with the normal app entrypoint.
- Layout tests include 320/1440 px, 200% text, both themes and keyboard navigation. A route-focus regression found during emulator inspection was corrected.
- No real-appliance mutation was attempted. Live write compatibility, other platform runners and full TrueNAS administration remain unverified/out of scope.
