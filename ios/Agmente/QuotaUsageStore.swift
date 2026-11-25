import Foundation
import ACPClient

enum ConnectionUsageState: Equatable {
    case unknown
    case supported
}

struct PersistedQuotaUsageRecord: Codable, Equatable {
    var hasConfirmedQuotaSupport: Bool
    var snapshot: NonlocalUsageResult?

    init(hasConfirmedQuotaSupport: Bool = false, snapshot: NonlocalUsageResult? = nil) {
        self.hasConfirmedQuotaSupport = hasConfirmedQuotaSupport
        self.snapshot = snapshot
    }
}

protocol QuotaUsageClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

struct SystemQuotaUsageClock: QuotaUsageClock {
    func now() -> Date { Date() }

    func sleep(seconds: TimeInterval) async throws {
        let clamped = max(0, seconds)
        let nanos = UInt64((clamped * 1_000_000_000.0).rounded())
        try await Task.sleep(nanoseconds: nanos)
    }
}

final class QuotaUsageStore {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, keyPrefix: String = "nonlocal.quotaUsage.v1.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func storageKey(for serverId: UUID) -> String {
        "\(keyPrefix)\(serverId.uuidString)"
    }

    func load(for serverId: UUID) -> PersistedQuotaUsageRecord? {
        guard let data = defaults.data(forKey: storageKey(for: serverId)) else {
            return nil
        }
        return try? decoder.decode(PersistedQuotaUsageRecord.self, from: data)
    }

    func save(_ record: PersistedQuotaUsageRecord, for serverId: UUID) {
        guard let data = try? encoder.encode(record) else { return }
        defaults.set(data, forKey: storageKey(for: serverId))
    }

    func clear(for serverId: UUID) {
        defaults.removeObject(forKey: storageKey(for: serverId))
    }
}

enum QuotaUsageMerger {
    /// Maximum allowed forward clock skew (seconds) before treating a local timestamp as dirty.
    static let maxFutureSkewSeconds: TimeInterval = 30.0

    static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) {
            return parsed
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    /// Evaluates whether `incoming` should replace `current` per DP-1.2 / AC-104:
    /// 1. First snapshot (`current == nil`) is always accepted.
    /// 2. If `current.fetchedAt` is dirty (> 30s in the future relative to `now`) and `incoming` has a valid `fetchedAt`,
    ///    accept the bridge's authoritative reading to self-heal clock skew.
    /// 3. Strictly newer `incoming.fetchedAt` is always accepted (clearing stale `lastError` when `incoming.lastError == nil`).
    /// 4. Same `fetchedAt` (including both `nil`) is accepted when `lastError`, `tier`, or `groups` changed.
    static func shouldAccept(
        incoming: NonlocalUsageResult,
        current: NonlocalUsageResult?,
        now: Date
    ) -> Bool {
        guard let current else { return true }

        let incomingDate = parseISO8601(incoming.fetchedAt)
        let currentDate = parseISO8601(current.fetchedAt)

        if let currentDate,
           currentDate.timeIntervalSince(now) > maxFutureSkewSeconds,
           incomingDate != nil {
            return true
        }

        if let incomingDate, let currentDate {
            if incomingDate > currentDate {
                return true
            }
            if incomingDate < currentDate {
                return false
            }
        } else if incomingDate != nil && currentDate == nil {
            return true
        } else if incomingDate == nil && currentDate != nil {
            return false
        }

        // Same fetchedAt (or both nil): allow updates to lastError, tier, or groups.
        return incoming.lastError != current.lastError
            || incoming.tier != current.tier
            || incoming.groups != current.groups
            || incoming.refreshing != current.refreshing
            || incoming.ageSeconds != current.ageSeconds
    }

    static func merge(
        incoming: NonlocalUsageResult,
        current: NonlocalUsageResult?,
        now: Date
    ) -> NonlocalUsageResult {
        guard shouldAccept(incoming: incoming, current: current, now: now) else {
            return current ?? incoming
        }
        return incoming
    }

    /// Computes the next foreground poll delay: `max(1s, ttl - effectiveAge)`.
    static func nextRefreshDelay(
        snapshot: NonlocalUsageResult?,
        now: Date
    ) -> TimeInterval {
        let ttl = TimeInterval(max(1, snapshot?.ttlSeconds ?? 180))
        if let age = snapshot?.ageSeconds {
            return max(1.0, ttl - TimeInterval(max(0, age)))
        }
        if let fetchedDate = parseISO8601(snapshot?.fetchedAt) {
            let elapsed = now.timeIntervalSince(fetchedDate)
            if elapsed < -maxFutureSkewSeconds {
                // Dirty future timestamp: re-probe immediately.
                return 1.0
            }
            return max(1.0, ttl - max(0, elapsed))
        }
        return ttl
    }

    /// Returns whether a cached snapshot needs an on-demand bridge check right now.
    static func needsRefresh(
        snapshot: NonlocalUsageResult?,
        now: Date
    ) -> Bool {
        guard let snapshot else { return true }
        guard let fetchedDate = parseISO8601(snapshot.fetchedAt) else { return true }
        let ttl = TimeInterval(max(1, snapshot.ttlSeconds))
        let elapsed = now.timeIntervalSince(fetchedDate)
        if elapsed < -maxFutureSkewSeconds {
            return true
        }
        if let age = snapshot.ageSeconds, TimeInterval(age) >= ttl {
            return true
        }
        return elapsed >= ttl
    }
}

enum QuotaUsageFormatter {
    static func percentageText(remainingFraction: Double) -> String {
        let clamped = min(max(remainingFraction, 0.0), 1.0)
        return "\(Int((clamped * 100.0).rounded()))%"
    }

    static func formatResetTime(
        window: String,
        resetTime: String?,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = AppLocalization.effectiveLocale
    ) -> String? {
        guard let resetDate = QuotaUsageMerger.parseISO8601(resetTime) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone

        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "HH:mm"
        let hhmm = timeFormatter.string(from: resetDate)

        let remaining = resetDate.timeIntervalSince(now)
        if remaining <= 0 {
            return AppLocalization.localized("Resetting soon · \(hhmm)", locale: locale)
        }

        if window.lowercased() == "weekly" {
            let weekdayIndex = max(1, min(7, calendar.component(.weekday, from: resetDate))) - 1
            let weekdaySymbol: String
            if let symbols = timeFormatter.shortWeekdaySymbols, weekdayIndex < symbols.count {
                weekdaySymbol = symbols[weekdayIndex]
            } else {
                let weekdayFormatter = DateFormatter()
                weekdayFormatter.calendar = calendar
                weekdayFormatter.locale = locale
                weekdayFormatter.timeZone = timeZone
                weekdayFormatter.dateFormat = "EEE"
                weekdaySymbol = weekdayFormatter.string(from: resetDate)
            }
            return AppLocalization.localized("Resets \(weekdaySymbol) \(hhmm)", locale: locale)
        }

        let durationFormatter = DateComponentsFormatter()
        durationFormatter.calendar = calendar
        durationFormatter.unitsStyle = .abbreviated
        durationFormatter.allowedUnits = [.hour, .minute]
        durationFormatter.zeroFormattingBehavior = .dropAll
        let clampedRemaining = max(60.0, remaining)
        let durationText = durationFormatter.string(from: clampedRemaining) ?? "1m"
        return AppLocalization.localized("In \(durationText) · \(hhmm)", locale: locale)
    }

    static func formatUpdatedAt(
        fetchedAt: String?,
        now: Date,
        locale: Locale = AppLocalization.effectiveLocale
    ) -> String? {
        guard let fetchedDate = QuotaUsageMerger.parseISO8601(fetchedAt) else {
            return nil
        }
        let elapsed = max(0, now.timeIntervalSince(fetchedDate))
        if elapsed < 60 {
            return AppLocalization.localized("Just now", locale: locale)
        }
        let minutes = Int(elapsed / 60.0)
        if minutes < 60 {
            return AppLocalization.localized("Updated \(minutes)m ago", locale: locale)
        }
        let hours = minutes / 60
        if hours < 24 {
            return AppLocalization.localized("Updated \(hours)h ago", locale: locale)
        }
        let days = hours / 24
        return AppLocalization.localized("Updated \(days)d ago", locale: locale)
    }

    static func shortGroupName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 14 {
            return trimmed
        }
        let simplified = trimmed
            .replacingOccurrences(of: "Google ", with: "")
            .replacingOccurrences(of: "Antigravity ", with: "")
        return simplified
    }
}
