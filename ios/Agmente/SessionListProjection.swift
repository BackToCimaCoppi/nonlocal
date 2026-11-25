import SwiftUI
import ACPClient

let healthyGreen = Color(.sRGB, red: 73/255, green: 210/255, blue: 123/255, opacity: 1)

enum NewSessionDefaults {
    /// Resolves the initial working directory for a new session target server (SD-2.8 / SC-AC-049).
    /// Falls back to "~" when targetServerId is nil or not found — never reads global selected server.
    static func resolveWorkingDirectory(
        preselectedServerId: UUID?,
        servers: [ACPServerConfiguration]
    ) -> String {
        guard let targetId = preselectedServerId,
              let server = servers.first(where: { $0.id == targetId }) else {
            return "~"
        }
        return server.workingDirectory
    }
}

extension SessionRowStatus {
    var dotColor: Color {
        switch self {
        case .running:
            return .orange
        case .unread:
            return healthyGreen
        case .read:
            return Color(.systemGray4)
        }
    }

    var accessibilityLabelText: String {
        switch self {
        case .running:
            return "Running"
        case .unread:
            return "Unread"
        case .read:
            return "Read"
        }
    }
}


struct SessionDisplay: Identifiable {
    let summary: SessionSummary
    let status: SessionRowStatus

    var id: String { summary.id }
}


enum SessionTimeGroup: CaseIterable, Hashable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case earlier
    case unknown

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .thisWeek:
            return "This week"
        case .lastWeek:
            return "Last week"
        case .thisMonth:
            return "This month"
        case .lastMonth:
            return "Last month"
        case .earlier:
            return "Earlier"
        case .unknown:
            return "Unknown"
        }
    }

    static var displayOrder: [SessionTimeGroup] {
        [.today, .yesterday, .thisWeek, .lastWeek, .thisMonth, .lastMonth, .earlier, .unknown]
    }

    static func group(for date: Date?, calendar: Calendar = .current) -> SessionTimeGroup {
        guard let date else { return .unknown }
        let now = Date()

        if calendar.isDateInToday(date) {
            return .today
        }

        if calendar.isDateInYesterday(date) {
            return .yesterday
        }

        if let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now), currentWeek.contains(date) {
            return .thisWeek
        }

        if let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now),
           let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek.start),
           let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastWeekStart),
           lastWeek.contains(date) {
            return .lastWeek
        }

        if let currentMonth = calendar.dateInterval(of: .month, for: now), currentMonth.contains(date) {
            return .thisMonth
        }

        if let currentMonth = calendar.dateInterval(of: .month, for: now),
           let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: currentMonth.start),
           let lastMonth = calendar.dateInterval(of: .month, for: lastMonthStart),
           lastMonth.contains(date) {
            return .lastMonth
        }

        return .earlier
    }
}

struct SessionFolderGroup: Hashable, Identifiable {
    let path: String
    let displayName: String

    var id: String { path }

    static func make(from cwd: String?, defaultCwd: String?) -> SessionFolderGroup {
        let raw = cwd ?? defaultCwd ?? ""
        let normalized = raw.hasSuffix("/") && raw.count > 1
            ? String(raw.dropLast())
            : raw
        guard !normalized.isEmpty else {
            return SessionFolderGroup(path: "", displayName: "No Folder")
        }
        let last = (normalized as NSString).lastPathComponent
        let display = last.isEmpty ? normalized : last
        return SessionFolderGroup(path: normalized, displayName: display)
    }
}

enum SessionListProjection {
    static let maxSessionsPerFolder = 5

    static func groupByTime(
        _ summaries: [SessionSummary],
        statusProvider: (String) -> SessionRowStatus
    ) -> [(group: SessionTimeGroup, sessions: [SessionDisplay])] {
        let sorted = summaries.sorted(by: SessionSummary.compareByUpdatedAtDesc)
        var buckets: [SessionTimeGroup: [SessionDisplay]] = [:]
        for summary in sorted {
            let group = SessionTimeGroup.group(for: summary.updatedAt)
            buckets[group, default: []].append(
                SessionDisplay(summary: summary, status: statusProvider(summary.id))
            )
        }
        return SessionTimeGroup.displayOrder.compactMap { group in
            guard let sessions = buckets[group], !sessions.isEmpty else { return nil }
            return (group, sessions)
        }
    }

    static func groupByFolder(
        _ summaries: [SessionSummary],
        defaultCwd: String?,
        statusProvider: (String) -> SessionRowStatus
    ) -> [(group: SessionFolderGroup, sessions: [SessionDisplay], hasMore: Bool)] {
        var buckets: [SessionFolderGroup: [SessionSummary]] = [:]
        for summary in summaries {
            let group = SessionFolderGroup.make(from: summary.cwd, defaultCwd: defaultCwd)
            buckets[group, default: []].append(summary)
        }

        return buckets
            .map { group, items in
                let sorted = items.sorted(by: SessionSummary.compareByUpdatedAtDesc)
                let limited = sorted.prefix(maxSessionsPerFolder).map {
                    SessionDisplay(summary: $0, status: statusProvider($0.id))
                }
                return (
                    group: group,
                    sessions: limited,
                    hasMore: sorted.count > maxSessionsPerFolder,
                    latestSummary: sorted.first
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.latestSummary, rhs.latestSummary) {
                case let (l?, r?):
                    if l.updatedAt != r.updatedAt {
                        switch (l.updatedAt, r.updatedAt) {
                        case let (ld?, rd?): return ld > rd
                        case (_?, nil): return true
                        case (nil, _?): return false
                        case (nil, nil): break
                        }
                    }
                    if lhs.group.path != rhs.group.path {
                        return lhs.group.path < rhs.group.path
                    }
                    return l.id < r.id
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.group.path < rhs.group.path
                }
            }
            .map { (group: $0.group, sessions: $0.sessions, hasMore: $0.hasMore) }
    }

    static func sessionsInFolder(
        _ summaries: [SessionSummary],
        folderPath: String,
        defaultCwd: String,
        query: String,
        statusProvider: (String) -> SessionRowStatus
    ) -> [SessionDisplay] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return summaries
            .filter { session in
                let sessionCwd: String
                if let cwd = session.cwd {
                    sessionCwd = cwd.hasSuffix("/") && cwd.count > 1
                        ? String(cwd.dropLast()) : cwd
                } else {
                    sessionCwd = defaultCwd
                }
                return folderPath.isEmpty
                    ? sessionCwd.isEmpty
                    : sessionCwd == folderPath
            }
            .filter { session in
                guard !trimmedQuery.isEmpty else { return true }
                return (session.title?.lowercased().contains(trimmedQuery) ?? false)
                    || session.id.lowercased().contains(trimmedQuery)
            }
            .sorted(by: SessionSummary.compareByUpdatedAtDesc)
            .map { SessionDisplay(summary: $0, status: statusProvider($0.id)) }
    }
}


struct SessionCardStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(colorScheme == .dark ? Color(.secondarySystemBackground) : Color.white)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 10, y: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(.systemGray5).opacity(colorScheme == .dark ? 0.4 : 1), lineWidth: colorScheme == .dark ? 0.5 : 1)
            )
    }
}


extension View {
    func sessionCardStyle() -> some View {
        self.modifier(SessionCardStyle())
    }
}

/// A simple flow layout that wraps items horizontally.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .init(frame.size))
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return (CGSize(width: totalWidth, height: currentY + lineHeight), frames)
    }
}
