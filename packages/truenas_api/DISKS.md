# Native disk settings — bounded TS-25.10.1 contract

TD-022 is partial: passive inventory and reviewed description / ATA HDD standby / advanced power-management settings. This is not a complete disk-maintenance, health-diagnostic or destructive storage workflow. No NAS connection, supplied credential, SSH session or live write was used; tests use an in-memory JSON-RPC transport only.

## Pinned public source

- [Disk API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/disk.py): identifier-based `disk.update`, public standby/APM enums, nullable size/type/rotation metadata, and no supported SMART enable field.
- [Disk query and update implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/disk.py): default unexpired inventory; explicit `passwords:false` removes password/KMIP fields; `pools:true` joins boot/imported ownership. Update shallow-merges the provided keys into the stored record before datastore persistence, preserving omitted fields. Changed power fields trigger power management afterward. Its return is an unjoined disk row, so returned `pool:null` is not treated as ownership evidence.
- [Linux power implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/disk_/power_management_linux.py): asynchronous `hdparm -B`; standby `-S` work is delayed about 60 seconds. Commands use unchecked return codes. Successful settings readback establishes stored configuration only, never hardware acceptance, sleep, power state or durability of the hardware configuration. Preflight cannot prevent another administrator or hot-swap racing these delayed commands.
- [Public device entry point](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/device.py), [device API](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/device.py), [device implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/device_/device_info.py): `device.get_info` with DISK/`serials_only:true` reads udev serial properties. It bypasses full details and their rotational-speed SCSI ioctl. No partitions are requested.
- [Identifier construction](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/disks.py): serial/LUN identifiers take precedence over serial identifiers, followed by partition UUID or device-name fallbacks. Only an exact serial-based identifier with a globally unique, matching passive name/serial is editable here; fallback/duplicate/missing identities remain display-only. LUN and capacity remain cached metadata, not newly probed hardware values.
- [Boot disk query](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/boot.py): public `boot.get_disks` uses the server's boot-disk cache. Boot power settings are blocked; description-only edits remain available when identity is verified.
- [Temperature implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/disk_/temperature.py): `disk.temperatures` refreshes missing/stale cache by probing hardware; it is never called. Historical aggregates are separate reporting data and are not presented as live temperature. Native disk temperature is explicitly unknown.
- [SMART migration helper](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/disk_/smart.py): `disk.smart_test` is private, migration-oriented functionality following removal of SMART UI/MW management. No guessed older-version SMART endpoint is used.

## Transport and privacy

All methods require stable 25.10 and authenticated, public, non-job, non-upload/download metadata. Inventory reads only:

1. `failover.licensed []`.
2. `disk.query [[], {limit:513, select:[identifier,name,serial,lunid,size,model,type,bus,description,hddstandby,advpowermgmt,pool,zfs_guid,rotationrate,expiretime], extra:{include_expired:false,passwords:false,pools:true}}]`.
3. `device.get_info [{type:DISK,get_partitions:false,serials_only:true}]`.
4. `boot.get_disks []`.
5. `core.get_jobs` filtered to WAITING/RUNNING, `limit:129`, projecting only id/method/state.

More than 512 disks/devices/boot entries or 128 jobs, malformed/missing required data, invalid types, duplicate identifiers/names/job IDs, expired rows or unsafe text fail closed. Server-violating extra fields are discarded immediately; DTOs, messages and review state never retain SED/password/KMIP/partition/SMART payloads. Error messages are fixed local text; remote traces are withheld. The RPC receipt can contain extra server fields but is never passed to generic UI rendering.

## Reviewed mutation boundaries

- Session-issued inventory and exact object identity are required. Public constructors support connector-free previews, not forged execute authority.
- Reviews are issued once, replaced by newer reviews, expire after five minutes, and require exact `UPDATE <identifier>` confirmation. Refresh consumes old reviews. Connection change, new HA licensing, visible jobs, hot-swap/name/serial drift, ownership/boot drift, or any cached target field/settings drift rejects before submission.
- Every visible WAITING/RUNNING job blocks changes; no attempt is made to infer safety from arbitrary job arguments. Job visibility is subject to server authorization and cannot prove the absence of invisible or non-job work. Imported pool ownership is not exhaustive dependency discovery: exported pools and other consumers are not declared absent.
- Description is bounded to 120 characters. Power changes use exact public enum values and are restricted to verified non-boot ATA HDDs. SSD/NVMe/unknown buses/types support description-only edits, preserving their existing power values.
- `disk.update [identifier, changedFieldsOnly]` sends only changed description/standby/APM keys. No SED field, defaults for unrelated settings, wipe, format, replace, partition or SMART operation is sent.
- The returned identifier/name/serial/settings must match. A subsequent complete passive inventory must show the same target identity/ownership and desired settings. The success message explicitly reports stored settings, not physical power state or disk health.
- All post-dispatch failures, including permissions errors, malformed receipt, timeout, connection replacement and readback drift, are sticky unknown: storage may already have changed and delayed hardware work may exist. No retry, rollback or polling runs automatically. Manual reads do not release the shared mutation fence; inspecting the original server and reconnecting is required.

## Verification

Focused SDK fake-wire tests cover passive request shapes, bounded projections, malformed inventory, enums/validation, exact changed-field patches, unsupported power targets, identity/ownership/jobs/HA drift, forged/consumed reviews, session changes, sanitized errors, all post-dispatch uncertainty, pending locks and cross-family zero-frame fences. Flutter UI and connector-free preview tests are owned by the app integration task.
