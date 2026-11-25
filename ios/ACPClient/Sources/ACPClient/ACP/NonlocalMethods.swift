import Foundation

/// Nonlocal bridge JSON-RPC extensions.
///
/// These methods are **not** part of the ACP spec. They extend `Nonlocal`'s
/// local `nonlocal-bridge` (`packages/bridge`) to preserve active turn state and config snapshots
/// across WebSocket disconnects without triggering destructive `session/load`
/// replays. Standard ACP agents will respond with `-32601` (Method not found),
/// and callers degrade gracefully.
public enum NonlocalMethods {
    /// Requests the bridge's current instance ID, materialized session list,
    /// cached config snapshots, and any buffered active/completed turn events.
    public static let sessionSync = "nonlocal/sync"

    /// Bridge-emitted server notification sent to synced clients when a
    /// tracked prompt turn completes or fails asynchronously.
    public static let turnCompleted = "nonlocal/turn_completed"

    /// Bridge-emitted notification sent when an underlying agent trajectory
    /// advances silently after a turn ended (for example, background commands).
    public static let sessionStale = "nonlocal/session_stale"

    /// Parameter metadata key carried inside `session/prompt` `params._meta`
    /// to associate client-initiated turns across reconnects.
    public static let clientTurnIdMetaKey = "nonlocalClientTurnId"

    /// Parameter metadata key attached by the bridge to live `session/update`
    /// notifications for deterministic deduplication after `nonlocal/sync`.
    public static let seqMetaKey = "nonlocalSeq"

    /// Optional parameter metadata key identifying the bridge turn ID that
    /// emitted a live `session/update`, scoping sequence deduplication to one turn.
    public static let turnIdMetaKey = "nonlocalTurnId"

    /// Bridge-supported JSON-RPC method to set or clear a session's manual custom title.
    /// Standard ACP agents return `-32601` (Method not found).
    public static let renameSession = "nonlocal/rename_session"

    /// Parameter metadata key carried inside `session/new` `params._meta`
    /// to pass the client-selected default model ID/family to the bridge.
    public static let defaultModelMetaKey = "nonlocalDefaultModel"

    /// Parameter metadata key carried inside `session/new` `params._meta`
    /// to pass the client-selected default thinking level to the bridge.
    public static let defaultThoughtLevelMetaKey = "nonlocalDefaultThoughtLevel"

    /// Queries the bridge's cached/single-flight Antigravity model pool quota snapshot.
    /// Standard ACP agents return `-32601` (Method not found).
    public static let usage = "nonlocal/usage"

    /// Bridge-emitted server notification pushed when a background quota refresh
    /// completes (success or failure) or when session-level `tier` updates.
    public static let usageUpdated = "nonlocal/usage_updated"

    /// Queries read-only session metadata (display/upstream title, cwd, and
    /// recursively discovered subagent sessions) for a bridge-owned session.
    public static let sessionInfo = "nonlocal/session_info"

    /// Bridge-emitted server notification sent when a session is confirmed
    /// externally deleted in IDE/TUI and pruned from bridge state.
    public static let sessionDeleted = "nonlocal/session_deleted"

    /// Lists directories (and optionally files) on the bridge host for directory
    /// picking and remote file browsing.
    public static let fsList = "nonlocal/fs_list"

    /// Reads a bounded slice of a remote text or image file on the bridge host
    /// for read-only preview.
    public static let fsReadFile = "nonlocal/fs_read_file"

    /// Deletes a persisted session (and any child subagents) on the bridge host.
    /// Standard ACP agents return `-32601` (Method not found).
    public static let deleteSession = "nonlocal/delete_session"
}
