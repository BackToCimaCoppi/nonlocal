# Nonlocal iOS Client

Nonlocal is a native iOS/iPadOS client designed exclusively for the Nonlocal ACP Bridge (`packages/bridge`, CLI `nonlocal-bridge`).

## Key capabilities
- Connect concurrently to one or more Nonlocal Bridge servers over `ws://` or `wss://` with required Bearer token authentication
- Strict Nonlocal Bridge admission (`initialize` + `nonlocal/sync` identity verification) and automatic 5-path protocol-incompatibility lockout with in-place recovery
- Multi-server aggregated and single-server home views, project directory aliases, 3-state activity dots, Antigravity quota cards, remote file/directory preview, inline slash-command autocomplete, and offline Mermaid rendering
- 8-language localization (`en`, `zh-Hans`, `zh-Hant`, `ko`, `ru`, `es`, `fr`, `de`)

## Repository layout
- `Agmente/` — SwiftUI & UIKit iOS app source
- `ACPClient/` — Typed Swift package for ACP + Nonlocal bridge extension protocol (`NonlocalMethods`)
- `AgmenteTests/` — Unit, Core Data migration, architecture audit, and multi-server state-machine tests
- `AgmenteUITests/` — iOS Simulator UI automation tests

## Requirements
- Xcode (iOS SDK + Simulator runtime)
- macOS for building and running tests

## Build & Tests

ACPClient package tests (runs directly on macOS):
```bash
swift test --package-path ios/ACPClient --disable-automatic-resolution
```

iOS app unit tests (Simulator):
```bash
xcodebuild test \
  -project ios/Agmente.xcodeproj \
  -scheme Agmente \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  -only-testing:AgmenteTests
```

Bridge setup & end-to-end verification: see `packages/bridge/README.md` and `docs/quickstart.md`.

## License
MIT. See repository root `LICENSE` and `THIRD_PARTY_LICENSES.md`.
