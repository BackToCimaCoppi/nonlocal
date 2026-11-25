# Nonlocal iOS App Layer Guide

## Scope
SwiftUI & UIKit iOS/iPadOS client dedicated exclusively to the Nonlocal ACP Bridge (`packages/bridge` / `nonlocal-bridge`):
- Single-bridge server admission, multi-server connection pool, and protocol-incompatibility lockout
- Multi-server aggregated & single-server session list, project aliases, and remote file/directory browsing
- Clean conversational chat transcript, offline Mermaid rendering, and quota management

## Modular Architecture
`AppViewModel` is a thin coordinator composing five dedicated components plus focused view and ViewModel files:
- **`ServerConnectionPool.swift`**: Single-track per-server `ServerConnectionSlot` lifecycle (`slots`, per-slot `updates` logs, `service(for:)` strictly `nil` when not `.connected`, 3-state `ScenePhase` handling, 4001 preemption, 5-path protocol-incompatibility lockout, and multi-server network recovery via `resumeAllEligibleOnNetworkRecovery` with `verifyConnectionHealth()` `ping()` probing for half-open sockets).
- **`BridgeServerValidator.swift`**: Single source of truth for endpoint normalization (`normalizeEndpoint`), local-network host detection, persistent `X-Client-Id`, and strict Nonlocal Bridge admission (`initialize` + `nonlocal/sync` non-empty trimmed `instanceId`), deterministically closing temporary sockets on every path.
- **`BridgeSyncCoordinator.swift`**: Exclusively owns per-server `initialSyncTask`, `initialSyncGeneration`, `activeSyncServiceObjectId`, `syncedServiceObjectId`, `isSyncingByServer`, and all 4 live-event buffers (`liveUpdates`, `turnCompleted`, `sessionStale`, `sessionDeleted`) with fixed 4-step replay order and monotonic `nonlocalSeq` deduplication.
- **`QuotaManager.swift` & `QuotaUsageStore.swift`**: Multi-server quota ingestion and persistence (accepting background `nonlocal/usage_updated` pushes for any bound server while migrating the 3-minute foreground refresh timer exclusively to the selected server; preserving cached snapshots on all errors including `-32601` without `.unsupported`).
- **`ChatMessageCache.swift`**: Pure in-memory `ACPSessionCacheDelegate` cache (zero `ServerViewModel` / `SessionStorage` dependency); Core Data persistence is owned separately by `ServerViewModel` via `ACPSessionStorageDelegate`.
- **`PassiveStreamingSettler.swift`**: Unidirectional passive streaming settle state machine with injectable delays (zero `ACPSessionViewModel` dependency).
- **Models & Views**: `ServerConfiguration.swift`, `ChatModels.swift`, `SessionListProjection.swift`, `HomeSessionListView.swift`, `NewSessionSheet.swift`, `SessionDetailView.swift`, `SessionComposerView.swift`, `WorkingDirectoryPickerSheet.swift`, `ServerViewModel+SessionList.swift`, `ServerViewModel+SessionLifecycle.swift`, `ACPSessionViewModel+Transcript.swift`, `ACPSessionViewModel+Permissions.swift`, and `#if DEBUG` `AppViewModel+DebugSeed.swift`.

## Architecture Invariants
- **Single-track connection pool**: All connections (1 server or N servers) run through `ServerConnectionPool` via `connectAllServers()`. `AppViewModel` does not conform to `ACPClientManagerDelegate`; slots forward events with explicit `serverId` via `ServerConnectionSlotDelegate`.
- **Closed Nonlocal Bridge admission & runtime lockout**:
  - `AddServerView` requires non-empty trimmed `name`, `host`, and `token`; saves directly without secondary confirmation modal on validation success; displays real-time `rootWorkingDirectoryWarning` when working directory is `/`.
  - Editing a server without changing normalized `scheme`, `host`, or `trimmedToken` skips remote validation, preserves an active connection (avoiding `4001` self-preemption), and preserves any existing protocol-incompatibility lockout state & red banner.
  - Runtime business RPCs (`session/list`, `nonlocal/fs_list`, `nonlocal/usage`, `loadPendingSessionIfPossible`) are strictly gated behind successful `nonlocal/sync` (valid non-empty `instanceId`).
  - Pre-sync `initialize` non-ACP/protocol errors (`{}`, `-32601`/`-32600`/`-32602`, excluding `"already initialized"`) or `nonlocal/sync` failures (`-32601`/`-32600`/`-32602` or `parseSyncResult == nil`) drop all 4 sync buffers, never mark sync completed, disconnect immediately, set `isProtocolIncompatible = true` (isolated from `wasPreempted == false`), and block all 5 automatic reconnect paths (`scheduleReconnectAttempt`, network recovery, `ScenePhase.active`, `SessionListPage.onAppear`, `connectAllServers`). Only explicit manual actions (editing connection params, manual connect, pull-to-refresh) unlock.
  - `HomeSessionListView` renders an independent red `nonBridgeLockoutBanner` with per-server `nonBridgeEditButton_<uuid>` in both single-server and all-sessions modes, always visible regardless of `devModeEnabled`.
  - Transient bridge errors (`-32000`, `-32603`, HTTP `401`, timeout, `.localNetworkPermissionNeeded`) never trigger protocol lockout.
- **Full cross-server isolation (`TD-2` zeroed)**: All session, file browser, directory picker, info sheet, mode/config, deletion, and new-session actions route by explicit `serverId` rather than reading `model.selectedServerId` or unscoped global `model.*` state. Missing target servers fall back to `"~"`.
- **Core Data v3 & Startup Migration**: `Agmente v3.xcdatamodel` removes deprecated protocol/Cloudflare columns and `Item` entity while preserving `Agmente.xcdatamodel` (`v1`) and `Agmente v2.xcdatamodel` (`v2`) for automatic lightweight migration (`token.isOptional == true`). Cold launch migrates legacy `Agmente.clientId`/`Agmente.lastConnectedAt` to `ACPClientManager.*` and cleans up legacy UserDefaults/log artifacts.
- **ACP clean conversational transcript & permissions**: Filters `.agentThought`, completed `.toolCall`, `.plan`, and legacy `"Tool call:"` lines while preserving inline pending permission cards (`permissionOptions != nil`) and clearing them upon response/completion/cancel/replay/sync.
- **Per-server default model**: `DefaultModelPreferences` injects `_meta.nonlocalDefaultModel` and `_meta.nonlocalDefaultThoughtLevel` directly on `session/new` (`0` follow-up `session/set_config_option` calls); `session/load` never overrides model settings.
- **Remote session deletion & failed delivery recovery**: `nonlocal/delete_session` is gated by `!isPendingSession && hasCompletedNonlocalSync`, blocks active/waiting sessions, uses 1.5s pre-check timeout fallback, and prevents resurrection via `recentlyDeletedSessionGenerations`. Failed prompt deliveries preserve user text/images (`FailedPromptDelivery`) for manual restore without auto-sending or overwriting `promptText`.
- **3-state activity dots & sorting**: `SessionRowStatus` (`running` orange > `unread` green > `read` gray; non-foreground pending permission shows `.unread`), `SessionListProjection.groupByFolder` (max 5 rows/group, `group.path` tie-breaker), immutable `updatedAt` during streaming/rename/replay.
- **8-language localization & brand unification**: Strict 8-language catalog (`en`, `zh-Hans`, `zh-Hant`, `ko`, `ru`, `es`, `fr`, `de`; zero `ja`; fallback `en`), unified user-facing brand `Nonlocal`, preserving internal anchors `"Agmente iOS"`, `"Agmente.lastServerId"`, `"Tool call: "`, and Core Data `"Agmente"`.
- **Remote file preview & offline Mermaid**: `shouldSummarizeServerLog` redacts `nonlocal/fs_list` and `nonlocal/fs_read_file`; `.md`/`.gif`/`.svg` enforce `allowsContentJavaScript == false`; `.html` uses `http://nonlocal.local/`; bundled MIT `mermaid.min.js` runs in a single offscreen `WKWebView` with CSP `default-src 'none'`.

## Required Tests
- `StripCodexArchitectureAuditTests` & `LocalizationIntegrityTests`
- `BridgeAdmissionAndLockoutTests` & `CoreDataV3MigrationTests`
- `MultiServerConnectionPoolTests`, `SessionIsolationTests`, `SessionPruneAndInfoTests`, `SessionDotsAndSortingTests`
- `QuotaUsageTests`, `ACPSessionViewModelTests`, `ServerViewModelTests`, `AgentViewModelTests`, `ViewModelSyncTests`
- `DefaultModelPreferencesTests`, `RemoteDirectoryPickerTests`, `RemoteFilePreviewTests`, `ProjectStoreTests`, `ChatPathLinkTests`, `ChatRenderingTests`, `MermaidRenderingTests`, `MermaidRendererIntegrationTests`, `SlashCommandAutocompleteTests`, `ToolCallDiffLinesTests`
- Bridge integration & UI tests: verify against a local `packages/bridge` (`nonlocal-bridge`) instance with `AgmenteUITests`.
