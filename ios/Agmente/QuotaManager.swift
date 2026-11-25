import Foundation
import SwiftUI
import ACPClient

/// Owns per-server quota snapshots, persistence, push ingestion for all online servers,
/// and foreground 3-minute polling exclusively for the selected server (DEC-27 / DEC-28 / SD-2.4).
@MainActor
final class QuotaManager {
    private let store: QuotaUsageStore
    private let clock: any QuotaUsageClock

    private(set) var snapshotByServer: [UUID: NonlocalUsageResult] = [:]
    private(set) var confirmedSupportByServer: [UUID: Bool] = [:]
    private(set) var connectionUsageStateByServer: [UUID: ConnectionUsageState] = [:]
    private(set) var serviceServerBinding: [ObjectIdentifier: (serverId: UUID, endpointSignature: String)] = [:]
    private var refreshTask: Task<Void, Never>?
    private var isFetchInFlightByServer: Set<UUID> = []
    var isAppInForeground: Bool = true

    var selectedServerIdProvider: () -> UUID? = { nil }
    var serviceProvider: (UUID) -> ACPService? = { _ in nil }
    var endpointSignatureProvider: (UUID) -> String = { $0.uuidString }
    var onChange: () -> Void = {}

    init(store: QuotaUsageStore, clock: any QuotaUsageClock = SystemQuotaUsageClock()) {
        self.store = store
        self.clock = clock
    }

    deinit {
        refreshTask?.cancel()
    }

    func hydrate(for servers: [ACPServerConfiguration]) {
        for server in servers {
            if let record = store.load(for: server.id) {
                confirmedSupportByServer[server.id] = record.hasConfirmedQuotaSupport
                if let snapshot = record.snapshot {
                    snapshotByServer[server.id] = snapshot
                }
            }
        }
    }

    func bindService(_ service: ACPService, to serverId: UUID) {
        serviceServerBinding[ObjectIdentifier(service)] = (
            serverId: serverId,
            endpointSignature: endpointSignatureProvider(serverId)
        )
    }

    func unbindServices(for serverId: UUID) {
        serviceServerBinding = serviceServerBinding.filter { $0.value.serverId != serverId }
    }

    func boundServerId(for service: ACPService) -> UUID? {
        serviceServerBinding[ObjectIdentifier(service)]?.serverId
    }

    func resetConnectionUsageState(for serverId: UUID) {
        connectionUsageStateByServer[serverId] = .unknown
        isFetchInFlightByServer.remove(serverId)
        if selectedServerIdProvider() == serverId {
            cancelRefreshTimer()
        }
        onChange()
    }

    func clear(for serverId: UUID) {
        store.clear(for: serverId)
        snapshotByServer.removeValue(forKey: serverId)
        confirmedSupportByServer.removeValue(forKey: serverId)
        connectionUsageStateByServer.removeValue(forKey: serverId)
        isFetchInFlightByServer.remove(serverId)
        if selectedServerIdProvider() == serverId {
            cancelRefreshTimer()
        }
        onChange()
    }

    func snapshot(for serverId: UUID?) -> NonlocalUsageResult? {
        guard let serverId else { return nil }
        return snapshotByServer[serverId]
    }

    /// Single-server card always renders the unified Antigravity ACP quota card (SD-1.9).
    func shouldShowQuotaCard(for serverId: UUID?) -> Bool {
        serverId != nil
    }

    func cancelRefreshTimer() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Called whenever `selectedServerId` changes: cancels old timer and refreshes/schedules for the new server by TTL (DEC-27).
    func handleServerSelected(_ serverId: UUID?, service: ACPService?) {
        cancelRefreshTimer()
        guard let serverId, let service, isAppInForeground else { return }
        triggerRefreshIfNeeded(for: serverId, service: service, force: false)
    }

    /// Called on 3-state ScenePhase transitions (DEC-27).
    func handleScenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .inactive, .background:
            isAppInForeground = false
            cancelRefreshTimer()
        case .active:
            isAppInForeground = true
            if let serverId = selectedServerIdProvider(),
               let activeService = serviceProvider(serverId) {
                triggerRefreshIfNeeded(for: serverId, service: activeService, force: false)
            }
        @unknown default:
            break
        }
    }

    /// Triggers an on-demand fetch or schedules the next 3-minute foreground timer for `serverId`.
    /// Timers run exclusively for the currently selected server (DEC-27).
    func triggerRefreshIfNeeded(for serverId: UUID, service: ACPService, force: Bool = false) {
        guard selectedServerIdProvider() == serverId,
              serviceProvider(serverId) === service else {
            return
        }
        if serviceServerBinding[ObjectIdentifier(service)] == nil {
            bindService(service, to: serverId)
        }

        let currentState = connectionUsageStateByServer[serverId] ?? .unknown
        let currentSnapshot = snapshotByServer[serverId]
        let now = clock.now()

        let shouldFetch = force
            || currentState == .unknown
            || QuotaUsageMerger.needsRefresh(snapshot: currentSnapshot, now: now)

        if shouldFetch {
            guard !isFetchInFlightByServer.contains(serverId) else { return }
            isFetchInFlightByServer.insert(serverId)
            Task { @MainActor [weak self] in
                await self?.performFetch(for: serverId, service: service)
            }
        } else if isAppInForeground {
            scheduleNextRefresh(for: serverId, service: service)
        }
    }

    /// Executes `nonlocal/usage` RPC. On ANY error (including -32601, timeout, disconnect), preserves cached snapshot (DEC-28).
    func performFetch(for serverId: UUID, service: ACPService) async {
        defer {
            isFetchInFlightByServer.remove(serverId)
        }
        let expectedBinding = serviceServerBinding[ObjectIdentifier(service)]

        do {
            let result = try await service.fetchNonlocalUsage()
            guard !Task.isCancelled else { return }
            guard isServiceStillBoundToServer(service, serverId: serverId, expectedBinding: expectedBinding) else {
                return
            }
            connectionUsageStateByServer[serverId] = .supported
            confirmedSupportByServer[serverId] = true
            if let result {
                applySnapshot(result, for: serverId)
            } else {
                store.save(
                    PersistedQuotaUsageRecord(
                        hasConfirmedQuotaSupport: true,
                        snapshot: snapshotByServer[serverId]
                    ),
                    for: serverId
                )
            }
            onChange()
            if isAppInForeground && selectedServerIdProvider() == serverId {
                scheduleNextRefresh(for: serverId, service: service)
            }
        } catch {
            // DEC-28: Never clear cached snapshot or set `.unsupported` on any error (including -32601).
            // Preserve existing snapshot & persistence; schedule next poll only if still foreground selected.
        }
    }

    /// Accepts `nonlocal/usage_updated` pushes for ALL online servers, validating exact service binding & endpoint signature (DEC-27).
    func handleUsageUpdated(_ incoming: NonlocalUsageResult, from sourceService: ACPService?) {
        guard let sourceService else { return }
        let objId = ObjectIdentifier(sourceService)
        guard let binding = serviceServerBinding[objId],
              serviceProvider(binding.serverId) === sourceService,
              binding.endpointSignature == endpointSignatureProvider(binding.serverId) else {
            return
        }
        let serverId = binding.serverId
        connectionUsageStateByServer[serverId] = .supported
        confirmedSupportByServer[serverId] = true
        applySnapshot(incoming, for: serverId)
        onChange()
        if isAppInForeground && selectedServerIdProvider() == serverId {
            scheduleNextRefresh(for: serverId, service: sourceService)
        }
    }

    private func isServiceStillBoundToServer(
        _ service: ACPService,
        serverId: UUID,
        expectedBinding: (serverId: UUID, endpointSignature: String)?
    ) -> Bool {
        let objId = ObjectIdentifier(service)
        guard serviceProvider(serverId) === service,
              let binding = serviceServerBinding[objId],
              binding.serverId == serverId,
              binding.endpointSignature == endpointSignatureProvider(serverId) else {
            return false
        }
        if let expectedBinding, expectedBinding.endpointSignature != binding.endpointSignature {
            return false
        }
        return true
    }

    private func applySnapshot(_ incoming: NonlocalUsageResult, for serverId: UUID) {
        let now = clock.now()
        let current = snapshotByServer[serverId]
        let merged = QuotaUsageMerger.merge(incoming: incoming, current: current, now: now)
        snapshotByServer[serverId] = merged
        store.save(
            PersistedQuotaUsageRecord(
                hasConfirmedQuotaSupport: true,
                snapshot: merged
            ),
            for: serverId
        )
    }

    private func scheduleNextRefresh(for serverId: UUID, service: ACPService) {
        cancelRefreshTimer()
        guard isAppInForeground,
              selectedServerIdProvider() == serverId,
              serviceProvider(serverId) === service else {
            return
        }
        let delay = QuotaUsageMerger.nextRefreshDelay(
            snapshot: snapshotByServer[serverId],
            now: clock.now()
        )
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(seconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.isAppInForeground,
                  self.selectedServerIdProvider() == serverId,
                  self.serviceProvider(serverId) === service else {
                return
            }
            await self.performFetch(for: serverId, service: service)
        }
    }
}
