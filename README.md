# TrueDash

> An unofficial cross-platform TrueNAS client, currently implementing a deliberately small M0 connection foundation.

M0 now contains a Flutter connection screen and a pure-Dart JSON-RPC/session foundation. It validates secure endpoints, uses the platform's normal WSS TLS validation, performs the planned API-key handshake, and presents a safe server summary. It does not yet have real-server compatibility evidence and must not be read as a claim of live TrueNAS support.

## Documentation

- [Product plan](docs/planning/TRUEDASH_PRODUCT_PLAN.md)
- [Capability parity matrix](docs/planning/TRUEDASH_CAPABILITY_MATRIX.csv)
- [TrueNAS API research](docs/research/TRUENAS_API_RESEARCH.md)
- [NASDeck competitor research](docs/research/NASDECK_COMPETITIVE_RESEARCH.md)
- [M0 foundation design](docs/planning/M0_FOUNDATION_DESIGN.md)
- [M0 foundation implementation plan](docs/planning/M0_FOUNDATION_IMPLEMENTATION.md)
- [M0 implementation evidence](docs/planning/M0_IMPLEMENTATION_EVIDENCE.md)

## Current baseline

- Product target: TrueNAS 25.10.7
- Compatibility target: TrueNAS 25.04 and later through version/capability adapters
- M0 app targets: Android, iOS, macOS, Windows, Linux, and web
- M0 stack: Flutter app plus the pure-Dart `packages/truenas_api` package

## Status

M0 is intentionally limited to one secure connection vertical slice. SCRAM, credential persistence, certificate trust exceptions, reconnection, subscriptions/jobs, billing, ads, and telemetry are not implemented.

## Trademark notice

TrueDash is an unofficial third-party project and is not affiliated with, endorsed by, or certified by iXsystems, Inc. TrueNAS is a trademark of iXsystems, Inc.
