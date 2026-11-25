import SwiftUI
import ACPClient

struct QuotaUsageCardView: View {
    let snapshot: NonlocalUsageResult?
    let isCollapsed: Bool
    let now: Date

    private var groups: [NonlocalUsageGroup] {
        snapshot?.groups ?? []
    }

    private var isColdStartEmpty: Bool {
        snapshot?.fetchedAt == nil && groups.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isColdStartEmpty {
                coldStartPlaceholder
            } else if isCollapsed {
                compactGridA1
            } else {
                expandedBarsA
            }

            if let error = snapshot?.lastError {
                errorBanner(error)
            }
        }
    }

    private var coldStartPlaceholder: some View {
        HStack(spacing: 10) {
            Text("--%")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("No quota data")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tileBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("quotaColdStartPlaceholder")
    }

    private var compactGridA1: some View {
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                compactTile(for: group)
            }
        }
        .accessibilityIdentifier("quotaCompactGridA1")
    }

    private func compactTile(for group: NonlocalUsageGroup) -> some View {
        let fiveHour = group.buckets.first { $0.window.lowercased() == "5h" }
        let weekly = group.buckets.first { $0.window.lowercased() == "weekly" }
        let fallback = group.buckets.first

        return VStack(alignment: .leading, spacing: 4) {
            Text(QuotaUsageFormatter.shortGroupName(group.name))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                if let fiveHour {
                    metricChip(prefixKey: "5h", fraction: fiveHour.remainingFraction)
                }
                if let weekly {
                    metricChip(prefixKey: "Wk", fraction: weekly.remainingFraction)
                }
                if fiveHour == nil && weekly == nil, let fallback {
                    metricChip(rawPrefix: fallback.window, fraction: fallback.remainingFraction)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tileBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func metricChip(prefixKey: LocalizedStringKey, fraction: Double) -> some View {
        HStack(spacing: 2) {
            Text(prefixKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(QuotaUsageFormatter.percentageText(remainingFraction: fraction))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color(for: fraction))
        }
    }

    private func metricChip(rawPrefix: String, fraction: Double) -> some View {
        HStack(spacing: 2) {
            Text(rawPrefix)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(QuotaUsageFormatter.percentageText(remainingFraction: fraction))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color(for: fraction))
        }
    }

    private var expandedBarsA: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    ForEach(Array(group.buckets.enumerated()), id: \.offset) { _, bucket in
                        bucketBarRow(bucket)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(tileBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .accessibilityIdentifier("quotaExpandedViewA")
    }

    private func bucketBarRow(_ bucket: NonlocalUsageBucket) -> some View {
        let clamped = min(max(bucket.remainingFraction, 0.0), 1.0)
        let windowLower = bucket.window.lowercased()
        let resetText = QuotaUsageFormatter.formatResetTime(window: bucket.window, resetTime: bucket.resetTime, now: now)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if windowLower == "weekly" {
                    Text("Weekly Pool")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if windowLower == "5h" {
                    Text("5h Pool")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(bucket.name)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(QuotaUsageFormatter.percentageText(remainingFraction: clamped))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color(for: clamped))

                Spacer(minLength: 4)

                if let resetText {
                    Text(resetText)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(color(for: clamped))
                        .frame(width: max(2, geo.size.width * clamped))
                }
            }
            .frame(height: 5)
        }
    }

    private func errorBanner(_ error: NonlocalUsageError) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(error.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("quotaErrorBanner")
    }

    private var tileBackground: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private func color(for fraction: Double) -> Color {
        if fraction <= 0.15 {
            return .red
        } else if fraction <= 0.40 {
            return .orange
        } else {
            return .green
        }
    }
}
