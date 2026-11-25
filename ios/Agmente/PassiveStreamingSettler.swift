import Foundation
import ACPClient

struct PassiveStreamingSettleDelays: Sendable, Equatable {
    let usageAfterMessageNs: UInt64
    let messageNs: UInt64
    let thoughtOrCompletedToolNs: UInt64
    let activeToolNs: UInt64

    static let `default` = PassiveStreamingSettleDelays(
        usageAfterMessageNs: 1_500_000_000,
        messageNs: 3_000_000_000,
        thoughtOrCompletedToolNs: 15_000_000_000,
        activeToolNs: 60_000_000_000
    )
}

/// Standalone unidirectional passive-streaming settlement state machine (SD-2.5).
/// Holds all passive settle timers and tool tracking, communicating upward solely via `onSettle`.
@MainActor
final class PassiveStreamingSettler {
    private let delays: PassiveStreamingSettleDelays
    private var settleTask: Task<Void, Never>?
    private var settleToken: UInt64 = 0
    private var activeToolCallIds: Set<String> = []
    private var sawAgentMessage: Bool = false
    private var sawUsageAfterMessage: Bool = false
    private var shouldNotifyOnSettle: Bool = false
    private(set) var deferredStopCompletion: Bool = false

    /// Invoked once when the idle window elapses; argument indicates whether listeners should be notified.
    var onSettle: ((Bool) -> Void)?

    var hasUnresolvedPassiveToolCalls: Bool {
        !activeToolCallIds.isEmpty
    }

    var hasActiveWork: Bool {
        deferredStopCompletion || !activeToolCallIds.isEmpty
    }

    init(delays: PassiveStreamingSettleDelays = .default) {
        self.delays = delays
    }

    deinit {
        settleTask?.cancel()
    }

    func cancelTimer() {
        settleToken &+= 1
        settleTask?.cancel()
        settleTask = nil
    }

    func reset() {
        cancelTimer()
        activeToolCallIds.removeAll()
        sawAgentMessage = false
        sawUsageAfterMessage = false
        shouldNotifyOnSettle = false
        deferredStopCompletion = false
    }

    func markDeferredStopCompletion(
        hasUnresolvedToolCalls: Bool,
        notifyOnSettle: Bool,
        canSchedule: Bool
    ) {
        if hasUnresolvedToolCalls && activeToolCallIds.isEmpty {
            activeToolCallIds.insert("__nonlocal_unresolved_tool__")
        }
        deferredStopCompletion = true
        shouldNotifyOnSettle = notifyOnSettle
        if canSchedule {
            scheduleSettle()
        } else {
            cancelTimer()
        }
    }

    func trackEvent(
        _ event: ACPSessionUpdateEvent,
        hasExplicitActiveTurn: Bool,
        canSchedule: Bool
    ) {
        switch event {
        case .toolCall(let info):
            let key = (info.toolCallId?.isEmpty == false) ? info.toolCallId! : "__passive_unnamed_tool__"
            if Self.isTerminalToolCallStatus(info.status) {
                activeToolCallIds.remove(key)
            } else {
                activeToolCallIds.insert(key)
            }
        case .toolCallUpdate(let update):
            let key = (update.toolCallId?.isEmpty == false) ? update.toolCallId! : "__passive_unnamed_tool__"
            if Self.isTerminalToolCallStatus(update.status) {
                activeToolCallIds.remove(key)
                activeToolCallIds.remove("__nonlocal_unresolved_tool__")
                if update.toolCallId == nil {
                    activeToolCallIds.remove("__passive_unnamed_tool__")
                }
            } else if let status = update.status, !status.isEmpty {
                activeToolCallIds.remove("__nonlocal_unresolved_tool__")
                activeToolCallIds.insert(key)
            }
        default:
            break
        }

        guard !hasExplicitActiveTurn else { return }

        switch event {
        case .agentThought:
            sawUsageAfterMessage = false
            shouldNotifyOnSettle = true
            reschedule(canSchedule: canSchedule)
        case .agentMessage:
            sawAgentMessage = true
            sawUsageAfterMessage = false
            shouldNotifyOnSettle = true
            reschedule(canSchedule: canSchedule)
        case .toolCall, .toolCallUpdate:
            sawUsageAfterMessage = false
            shouldNotifyOnSettle = true
            reschedule(canSchedule: canSchedule)
        case .usageUpdate:
            if sawAgentMessage {
                sawUsageAfterMessage = true
            }
            if canSchedule {
                scheduleSettle()
            }
        case .userMessage, .modeChange, .configOptionsUpdate, .availableCommandsUpdate, .sessionInfoUpdate, .plan:
            break
        }
    }

    func reschedule(canSchedule: Bool) {
        guard canSchedule else {
            cancelTimer()
            return
        }
        scheduleSettle()
    }

    private func scheduleSettle() {
        let delayNs: UInt64 = {
            if !activeToolCallIds.isEmpty {
                return delays.activeToolNs
            }
            if sawUsageAfterMessage {
                return delays.usageAfterMessageNs
            }
            if sawAgentMessage {
                return delays.messageNs
            }
            return delays.thoughtOrCompletedToolNs
        }()

        cancelTimer()
        let token = settleToken
        settleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNs)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.settleToken == token else {
                return
            }
            let notify = self.shouldNotifyOnSettle
            self.onSettle?(notify)
        }
    }

    static func isTerminalToolCallStatus(_ status: String?) -> Bool {
        guard let lowered = status?.lowercased(), !lowered.isEmpty else { return false }
        return ["completed", "failed", "cancelled", "canceled", "rejected", "denied", "error"].contains(lowered)
    }
}
