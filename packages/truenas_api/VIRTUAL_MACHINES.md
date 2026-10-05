# Native virtual-machine workspace

This is a bounded native implementation for stable TrueNAS 25.10. It is not full VM/WebUI parity. All implementation verification uses synthetic transports, controller tests and widget tests. No NAS connection, credential or real-server write is used.

## Implemented workflows

- Bounded native inventory, UUID, power state, memory/CPU topology, boot/autostart settings and non-secret device summaries. An accessible donut/legend shows disjoint returned-inventory state counts, with explicit empty state and per-VM text/color badges; no utilization or uptime is inferred.
- Create a stopped VM definition, then attach devices in separate explicit reviews. The create API does not accept a device list. The client does not silently submit a sequence or automatically clean up a partially created VM.
- Stopped-VM configuration editor: name, description, CPU sockets/cores/threads, CPU mode/model choices, memory/minimum memory, autostart, UEFI/legacy firmware, clock mode, shutdown timeout, guest display availability, Hyper-V enlightenments and TPM. Only changed fields are sent. Secure boot, OVMF selection, CPU affinity and other unedited fields are retained.
- Start, graceful stop, restart, immediate poweroff, suspend, resume and storage-preserving VM deletion, each with a single-use review and exact typed VM-name confirmation.
- Attach or change an existing unused zvol, a server-issued NIC attachment, or a verified existing ISO/CDROM. Add a loopback-only SPICE display with web access disabled. Edit device/boot order without sending device attributes. Detach devices without removing their backing storage.
- Synthetic preview inventory and forms; its mutation and polling methods always reject and never access a transport.

## Source-specific safeguards

The public API is not a uniform job API. `vm.create`, `vm.update`, `vm.delete`, `vm.start`, `vm.poweroff`, `vm.suspend`, `vm.resume`, and device CRUD are synchronous. `vm.stop` and `vm.restart` are jobs. The gateway verifies a returned job's exact ID, method and arguments, then independently reads the VM. It never trusts a job's result/error/log text as configuration proof or exposes those texts to the UI.

`vm.restart` internally requests forced shutdown after timeout and starts with memory overcommit enabled. The review explicitly discloses both effects. Ordinary start uses `{overcommit:false}` and a fresh memory preflight. `vm.get_available_memory` returns bytes in the pinned implementation, despite MB wording in an API model.

`vm.delete` can automatically power off an active guest even with `force:false`. The gateway therefore requires STOPPED at review and again immediately before dispatch. Deletion always sends `{zvols:false,force:false}`. It removes VM/device definitions and guest UEFI state, not backing zvols/raw files, and makes no claim that retained storage has been freed. Device detach always sends `{force:false,raw_file:false,zvol:false}`. Raw-file resizing and zvol allocation are never hidden in device edits.

Inventory handles and resource options are session-issued. A review binds the exact ID/UUID, complete configuration/device fingerprints and current power state. Immediately before submission these are checked again after dependency reads. Disk choices are not sufficient on their own: they can include zvols attached to VMs, so fresh global VM inventory excludes other attachments. Selected zvols are additionally fenced by dataset GUID, creation, size, writable/unlocked state, and exact path. Guest start/restart/resume rechecks backing-disk identity. ISO attachment checks FILE type, inode, mount ID, device, size and modification/status-change time. Every parent, including `/mnt`, must independently report DIRECTORY with matching absolute spelling and stable inode/device/mount identity. This is necessary because pinned `filesystem.stat.realpath` resolves symlinks only for a symlink leaf, not its ancestors. The same parent proof protects RAW/CDROM guest-start paths. Paths are bounded to 32 components and 64 unique parent observations per VM storage check; ambiguous spelling, links, incomplete proofs or identity drift fail closed. Server-side authorization and final device validation remain authoritative.

The ISO review discloses that server readability validation can temporarily change file ownership and libvirt may adjust ownership when a guest starts. Path observations are not atomic with the server's eventual file open; the API does not expose an `openat`/`O_NOFOLLOW` operation that binds the checked directory chain to attachment. Concurrent external path replacement remains a documented race, not a promised isolation boundary.

Only a non-secret device-field allowlist is public. Existing display passwords, unknown attributes and advanced settings are represented internally by fingerprints, never copied into public review/provider models. Device updates are sparse; the server preserves unmodified attribute siblings. After a successful call, independent readback also verifies unedited fields/devices—including protected attributes—against those fingerprints.

The mutation lock is shared with other server workflows. Reviews are single-use even on incorrect confirmation or rejected preflight. A timeout, malformed response, failed/aborted job, identity mismatch or unexpected post-write state becomes uncertain and retains the mutation lock until the authenticated session changes. There is no automatic mutation retry or compensating cleanup. The controller polls only its issued job, with a bounded automatic read budget and manual progress checks thereafter. Changing profiles immediately hides every old inventory/form/review dialog. An already submitted unresolved operation retains its original endpoint, reviewed target/UUID and job ID in a clearly labeled original-server status, never as current-server success. A late receipt can add only that original job ID; it cannot restart polling on the new connection.

These APIs have no atomic compare-and-swap for VM UUID/configuration, zvol identity, file identity or attachment ownership. A concurrent external administrator can change a resource between the final read and dispatch. Fresh checks reduce that window but do not eliminate it. Creation/readback also cannot recover safely from a lost create response, so that outcome stays uncertain.

## Still outside this slice

Native display/serial streaming and console admission, secure-boot/OVMF creation choices, CPU affinity/topology-extension editing, PCI/USB passthrough, VM cloning, backing-zvol allocation, raw-image creation/resizing/conversion/import/export, guest-agent integration and VM log downloads remain unimplemented here. Existing storage must be prepared separately. Order collisions are rejected instead of implicitly reordering other devices. Remote listener/password configuration is not exposed by the local-only display action. Unsupported versions or missing required methods are explicitly rejected; no generic RPC editor bypasses these controls.

## Pinned primary contracts

- [25.10 VM models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/vm.py)
- [25.10 device models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/vm_device.py)
- [VM CRUD, UUID and deletion behavior](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/vm/vms.py)
- [Domain deletion removes NVRAM; updates preserve it](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/vm/supervisor/supervisor.py)
- [Lifecycle jobs, forced restart and overcommit](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/vm/vm_lifecycle.py)
- [Device choices, sparse attribute update and storage deletion flags](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/vm/vm_devices.py)
- [Available memory implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/vm/vm_memory_info.py)
- [Filesystem identity fields](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/filesystem.py)
- [Actual leaf-only realpath behavior](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/filesystem.py)
- [ISO readability and ownership validation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/vm/devices/cdrom.py)
- [Dataset property model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/pool_dataset.py)

Verification commands: `fvm dart test test/session/session_virtual_machines_test.dart` in `packages/truenas_api`, and `fvm flutter test test/features/virtual_machines/virtual_machines_test.dart` in `apps/truenavo`. These commands use only in-memory fake fixtures.

Current focused verification: 51 SDK tests and 24 controller/widget/preview tests pass. The SDK suite includes leaf-spelling-preserving symlink ancestors, missing directory proof, ancestor inode/device/mount drift, RAW/CDROM start rechecks and bounded/noncanonical paths. The UI suite includes 320px at 200% text scaling, unsupported-route retry suppression, all three modal session fences, original-server pending-operation provenance, count/badge semantics, empty inventory and 14px configuration/device-control spacing. All VM-owned Dart files analyze without diagnostics. This is fake-only implementation evidence, not live NAS validation or a full-parity claim.
