# Nonlocal Unit Tests Guide

## Scope
Unit, Core Data migration, architecture audit, and multi-server state-machine tests for the Nonlocal iOS app layer (`ios/AgmenteTests/`).

## Test Layers
- **Architecture & localization static audits**: `StripCodexArchitectureAuditTests`, `LocalizationIntegrityTests`.
- **Single-bridge admission, lockout & modular components**: `BridgeAdmissionAndLockoutTests`, `QuotaUsageTests`, `ServerViewModelTests`, `ACPSessionViewModelTests`, `AgentViewModelTests`, `ViewModelSyncTests`.
- **Multi-server connection pool & cross-server isolation**: `MultiServerConnectionPoolTests`, `SessionIsolationTests`, `SessionPruneAndInfoTests`, `SessionDotsAndSortingTests`, `RemoteDirectoryPickerTests`, `RemoteFilePreviewTests`.
- **Core Data & persistence**: `CoreDataV3MigrationTests` (real on-disk `v1`/`v2` → `v3` SQLite migration + legacy defaults/artifact cleanup), `SessionStorageTests`, `ProjectStoreTests`.
- **Rendering & composer**: `ChatRenderingTests`, `ChatPathLinkTests`, `MermaidRenderingTests`, `MermaidRendererIntegrationTests`, `SlashCommandAutocompleteTests`, `ToolCallDiffLinesTests`, `DefaultModelPreferencesTests`, `MultiServerHomeProjectionTests`.

## Test Design Rules
- Use single-track `AppViewModel` injection (`connectionManagerFactory:` or `defaultSlotServiceFactory:` + `validatorServiceFactory:`); prefer `defaultSlotServiceFactory:` with `shouldConnectOnStartup: true` and non-zero `selectedServerId` when testing real default connection-pool startup paths.
- Use isolated `UserDefaults(suiteName:)` and in-memory `SessionStorage.inMemory()` (or dedicated temp SQLite directories cleaned up in `tearDown` for Core Data disk migration tests).
- Avoid live network dependencies or touching active host ports (`127.0.0.1:8765`).
- Keep tests deterministic with virtual clocks (`QuotaUsageClock`), injectable delays (`PassiveStreamingSettleDelays`), and scripted `WebSocketConnection` doubles.

## Running
```bash
xcodebuild test \
  -project ios/Agmente.xcodeproj \
  -scheme Agmente \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  -only-testing:AgmenteTests
```
