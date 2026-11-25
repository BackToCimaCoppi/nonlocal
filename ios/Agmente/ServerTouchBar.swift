import SwiftUI
#if os(iOS)
import UIKit
#endif

public enum HomeDisplayMode: String, Codable, Equatable, Sendable {
    case allSessions
    case singleServer
}

public struct ServerTouchBarItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let isConnected: Bool
    public let isConnecting: Bool

    public init(id: UUID, name: String, isConnected: Bool, isConnecting: Bool) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.isConnecting = isConnecting
    }
}

public enum ServerTouchBarGestureLogic {
    public static let tapThreshold: CGFloat = 12
    public static let commitDistanceThreshold: CGFloat = 36

    public enum GestureOutcome: Equatable, Sendable {
        case tapToggleMode
        case selectIndex(Int)
        case springBack
        case ignored
    }

    public static func evaluateDragEnd(
        mode: HomeDisplayMode,
        translationX: CGFloat,
        predictedEndTranslationX: CGFloat,
        activeIndex: Int,
        serverCount: Int
    ) -> GestureOutcome {
        if abs(translationX) < tapThreshold && abs(predictedEndTranslationX) < tapThreshold * 2 {
            return .tapToggleMode
        }

        if mode == .allSessions {
            return .ignored
        }

        guard serverCount >= 2 else {
            return .springBack
        }

        let normalizedIndex = ((activeIndex % serverCount) + serverCount) % serverCount

        if translationX <= -commitDistanceThreshold || predictedEndTranslationX <= -commitDistanceThreshold {
            return .selectIndex((normalizedIndex + 1) % serverCount)
        }

        if translationX >= commitDistanceThreshold || predictedEndTranslationX >= commitDistanceThreshold {
            return .selectIndex((normalizedIndex - 1 + serverCount) % serverCount)
        }

        return .springBack
    }

    public static func usesNumericPageIndicator(serverCount: Int) -> Bool {
        serverCount > 5
    }
}

struct ServerTouchBar: View {
    let mode: HomeDisplayMode
    let items: [ServerTouchBarItem]
    let activeIndex: Int
    let onToggleMode: () -> Void
    let onSelectIndex: (Int) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isHorizontalDragLocked = false

    private static let barHeight: CGFloat = 44
    private static let onlineGreen = Color(.sRGB, red: 73 / 255, green: 210 / 255, blue: 123 / 255, opacity: 1)

    private var safeActiveIndex: Int {
        guard !items.isEmpty else { return 0 }
        return ((activeIndex % items.count) + items.count) % items.count
    }

    private var onlineCount: Int {
        items.filter(\.isConnected).count
    }

    private var activeItem: ServerTouchBarItem? {
        guard !items.isEmpty else { return nil }
        return items[safeActiveIndex]
    }

    private var accessibilityValueText: String {
        switch mode {
        case .allSessions:
            return "All Sessions (\(onlineCount)/\(items.count))"
        case .singleServer:
            if let activeItem {
                return "\(activeItem.name) (\(safeActiveIndex + 1)/\(items.count))"
            }
            return ""
        }
    }

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)

            Group {
                switch mode {
                case .allSessions:
                    allSessionsContent
                case .singleServer:
                    singleServerContent
                }
            }
        }
        .frame(height: Self.barHeight)
        .contentShape(Capsule(style: .continuous))
        .gesture(touchBarDragGesture)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("serverTouchBar")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(mode == .allSessions ? Text("All Sessions") : Text(activeItem?.name ?? ""))
        .accessibilityValue(Text(accessibilityValueText))
        .accessibilityAction(.default) {
            triggerLightHaptic()
            onToggleMode()
        }
    }

    private var allSessionsContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            Text("All Sessions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Circle()
                    .fill(onlineCount > 0 ? Self.onlineGreen : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)

                Text("\(onlineCount)/\(items.count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
    }

    private var singleServerContent: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let slotSpacing = max(width * 0.44, 110)

                ZStack {
                    ForEach(visibleRelativeOffsets, id: \.self) { relativeOffset in
                        let itemIndex = wrappedIndex(safeActiveIndex + relativeOffset)
                        let item = items[itemIndex]
                        let xOffset = CGFloat(relativeOffset) * slotSpacing + dragOffset
                        let normalizedDistance = min(abs(xOffset) / slotSpacing, 1.0)
                        let scale = 1.0 - (0.24 * normalizedDistance)
                        let opacity = 1.0 - (0.58 * normalizedDistance)
                        let dotOpacity = max(0, 1.0 - (normalizedDistance * 1.4))

                        serverWheelLabel(item: item, dotOpacity: dotOpacity)
                            .frame(maxWidth: width * 0.56)
                            .scaleEffect(scale)
                            .opacity(opacity)
                            .offset(x: xOffset)
                    }
                }
                .frame(width: width, height: proxy.size.height)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.14),
                            .init(color: .black, location: 0.86),
                            .init(color: .clear, location: 1.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
            .frame(height: 24)

            if items.count > 1 {
                pageIndicator
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var visibleRelativeOffsets: [Int] {
        guard !items.isEmpty else { return [] }
        if items.count == 1 {
            return [0]
        }
        if items.count == 2 {
            return [-1, 0, 1]
        }
        return [-1, 0, 1]
    }

    private func wrappedIndex(_ index: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        return ((index % items.count) + items.count) % items.count
    }

    private func serverWheelLabel(item: ServerTouchBarItem, dotOpacity: Double) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(for: item))
                .frame(width: 7, height: 7)
                .opacity(dotOpacity)

            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private var pageIndicator: some View {
        if ServerTouchBarGestureLogic.usesNumericPageIndicator(serverCount: items.count) {
            Text("\(safeActiveIndex + 1)/\(items.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            HStack(spacing: 4) {
                ForEach(0..<items.count, id: \.self) { index in
                    Circle()
                        .fill(index == safeActiveIndex ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.32))
                        .frame(width: index == safeActiveIndex ? 5 : 4, height: index == safeActiveIndex ? 5 : 4)
                }
            }
            .frame(height: 8)
        }
    }

    private func statusColor(for item: ServerTouchBarItem) -> Color {
        if item.isConnected {
            return Self.onlineGreen
        }
        if item.isConnecting {
            return .orange
        }
        return Color.secondary.opacity(0.45)
    }

    private var touchBarDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard mode == .singleServer, items.count >= 2 else { return }
                let translationX = value.translation.width
                if !isHorizontalDragLocked && abs(translationX) >= ServerTouchBarGestureLogic.tapThreshold {
                    isHorizontalDragLocked = true
                }
                if isHorizontalDragLocked {
                    let maxOffset: CGFloat = 140
                    dragOffset = min(max(translationX, -maxOffset), maxOffset)
                }
            }
            .onEnded { value in
                let outcome = ServerTouchBarGestureLogic.evaluateDragEnd(
                    mode: mode,
                    translationX: value.translation.width,
                    predictedEndTranslationX: value.predictedEndTranslation.width,
                    activeIndex: safeActiveIndex,
                    serverCount: items.count
                )

                isHorizontalDragLocked = false
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    dragOffset = 0
                }

                switch outcome {
                case .tapToggleMode:
                    triggerLightHaptic()
                    onToggleMode()
                case .selectIndex(let nextIndex):
                    triggerLightHaptic()
                    onSelectIndex(nextIndex)
                case .springBack, .ignored:
                    break
                }
            }
    }

    private func triggerLightHaptic() {
#if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
#endif
    }
}
