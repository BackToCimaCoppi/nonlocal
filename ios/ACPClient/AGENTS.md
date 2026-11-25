# ACPClient Package Guide

## Scope
Typed ACP + Nonlocal Bridge transport/service Swift package used by the Nonlocal iOS client (supports macOS host `swift test` execution).

## Architecture Model
- Transport (`ACPClient`, `WebSocketConnection`), request orchestration (`ACPService`, `ACPClientManager`), and parsing (`ACPInitializeParser`, `ACPResponseDispatcher`, `ACPSessionUpdateHandler`, `Nonlocal*`) are separated layers.
- Public service APIs remain typed and hide wire-format details from callers.
- Standard model selection config ID constant lives in `ACPModelConfig.configId == "model"` (applied via standard ACP `session/set_config_option`).

## Nonlocal Bridge Extension Methods
- Nonlocal-only JSON-RPC extensions live in `NonlocalMethods` (closed 11-method set:
  `nonlocal/sync`, `nonlocal/turn_completed`, `nonlocal/session_stale`,
  `nonlocal/rename_session`, `nonlocal/usage`, `nonlocal/usage_updated`,
  `nonlocal/session_info`, `nonlocal/session_deleted`, `nonlocal/delete_session`,
  `nonlocal/fs_list`, `nonlocal/fs_read_file`, plus `_meta` keys `nonlocalClientTurnId`,
  `nonlocalSeq`, `nonlocalTurnId`, `nonlocalDefaultModel`, `nonlocalDefaultThoughtLevel`),
  kept apart from `ACPMethods`.
- All 11 `NonlocalMethods` are short-circuited at the top of `ACPResponseDispatcher.dispatchSuccess` (returning `[]`) so responses carrying `sessionId` or `stopReason` never trigger `.sessionActivated` or generic ACP actions.
- `ACPResponseDispatcher.dispatchError` emits only `.rpcError` (no dynamic `.capabilityDisabled` degradation).
- `ACPInitializeParser.parse(result:)` strictly requires a valid ACP payload and returns `nil` for empty `{}` or non-ACP payloads.
- `NonlocalSessionSyncParser.parseSyncResult(from:)` trims whitespace on `instanceId` and strictly returns `nil` when empty/missing.
- `ACPSessionCreatePayload.meta` encodes non-empty `_meta` objects on `session/new` and omits `_meta` when empty.
- Typed `ACPService` wrappers cover extension RPCs: `syncNonlocalSessions()`, `renameSession(sessionId:title:)`, `fetchNonlocalUsage()`, `fetchSessionInfo(sessionId:)`, `deleteSession(sessionId:)`, `listDirectory(_:)`, and `readFile(path:)`.
- Filesystem (`-32011..-32016`) and session deletion (`-32021..-32024`) extension errors map via `NonlocalFsErrorCode` / `NonlocalDeleteErrorCode` through `ACPServiceError.rpcCode`.
- `ACPSessionListParser` treats explicit `"title": null` or `""` as intentionally blank, falling back to `"prompt"` only when `"title"` key is absent.
- `ACPSessionUpdateHandler` accepts both `currentModeId` and legacy `modeId` on `current_mode_update`, ignoring empty/whitespace-only values.
- `NonlocalSessionSnapshot` parses optional `availableCommands` (`[]` when absent).

## Transport & Reconnection Invariants
- `ACPConnectionConfig` carries `endpoint`, `authToken`, and `pingInterval` only (zero third-party proxy auth headers).
- `ACPService` fails all pending continuations on both `.disconnected` and `.failed`, rejects new requests immediately in `.failed`, and exposes read-only `lastCloseReason` from `ACPClient`.
- `ACPClient` guards `lastCloseReason` with an `NSLock`, cancels `pingTask` and clears `connection = nil` before transitioning to `.disconnected` on `.closed(reason)`, guards heartbeat errors with `Task.isCancelled || state != .connected`, and tracks handshake cancellation generation so `disconnect()` during an in-flight handshake closes late sockets cleanly without orphan connections.
- `ACPClientManager.disconnect()` synchronously detaches `service.delegate`, clears `service = nil`, sets `isConnecting = false` and `connectionState = .disconnected`, and notifies its delegate before closing the socket asynchronously.
- `ACPClientManager` stops auto-reconnect and sets `wasPreempted = true` strictly when `lastCloseReason?.code == 4001`, while keeping normal exponential backoff auto-reconnect for standard close codes (`1000`/`1006`) and clearing `wasPreempted` on explicit `connect(...)`.
- `ACPClientManager.verifyConnectionHealth()` runs `service.ping()` with timeout and disconnects + reconnects when half-open sockets fail health checks.
- Preserve support for server-initiated JSON-RPC requests (do not treat as transport errors).

## Tests
Run the full `ACPClient` package test suite (23 files) on macOS:
```bash
swift test --package-path ios/ACPClient --disable-automatic-resolution
```
