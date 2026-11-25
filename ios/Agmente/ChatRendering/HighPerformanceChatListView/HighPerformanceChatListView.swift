#if canImport(UIKit)
import UIKit
import ListViewKit
import MarkdownView
import ACP
import ACPClient

enum RowType {
    case userText
    case userImages
    case assistantMarkdown
    case assistantThought
    case assistantPlan
    case assistantMermaid
    case toolCall
    case fileChanges
    case system
    case error
    case streaming
}

enum MarkdownStyle {
    case assistant
    case thought
    case plan

    var backgroundColor: UIColor {
        switch self {
        case .assistant:
            return UIColor.systemGray6
        case .thought:
            return UIColor.systemGray6
        case .plan:
            return UIColor.systemBlue.withAlphaComponent(0.08)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .assistant, .thought, .plan:
            return 10
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .assistant:
            return 8
        case .thought, .plan:
            return 10
        }
    }
}

final class HighPerformanceChatListView: UIView {
    static let rowInsets = UIEdgeInsets(top: 0, left: 14, bottom: 12, right: 14)
    private static let thoughtExpandedHashSalt = 0x5F3759DF
    private let updateQueue = DispatchQueue(label: "agmente.chat.render.queue", qos: .userInteractive)

    private lazy var listView: ListViewKit.ListView = .init()
    private lazy var dataSource: ListViewDiffableDataSource<ChatEntry> = .init(listView: listView)

    private let mapper = ChatEntryMapper()
    private let markdownCache: ChatMarkdownPackageCache = .shared
    private let heightCache: ChatHeightCache = .shared
    private let renderGenerationLock = NSLock()
    private var _renderGeneration: UInt64 = 0
    private lazy var themeIdentity: Int = ChatMarkdownPackageCache.themeIdentity(for: theme)
    private lazy var thoughtTheme: MarkdownTheme = Self.makeThoughtMarkdownTheme(from: theme)
    private lazy var thoughtThemeIdentity: Int = ChatMarkdownPackageCache.themeIdentity(for: thoughtTheme)

    private lazy var sizingMarkdownView: MarkdownTextView = {
        let view = MarkdownTextView()
        view.throttleInterval = 1 / 60
        return view
    }()

    private var rawEntries: [ChatEntry] = []
    private var entries: [ChatEntry] = []
    private var renderedEntries: [ChatEntry] = []
    private var pendingEntries: [ChatEntry]?
    private var pendingEntriesAnimated: Bool = false
    private var pendingScrollToBottomAnimated: Bool = false
    private var expandedThoughtEntryIds: Set<String> = []
    private var mermaidRefreshSalt: Int = 0
    private var mermaidObserver: NSObjectProtocol?
    private var isAutoScrollingToBottom = true
    private var autoScrollTolerance: CGFloat = 4
    private var lastReportedAtBottom: Bool?

    var actionHandlers: ChatEntryActionHandlers = .none
    var config: ChatRendererConfig = .default {
        didSet {
            autoScrollTolerance = config.autoScrollTolerance
        }
    }

    var onAtBottomChanged: ((Bool) -> Void)?

    private(set) var theme: MarkdownTheme = .default {
        didSet {
            themeIdentity = ChatMarkdownPackageCache.themeIdentity(for: theme)
            let updatedThoughtTheme = Self.makeThoughtMarkdownTheme(from: theme)
            thoughtTheme = updatedThoughtTheme
            thoughtThemeIdentity = ChatMarkdownPackageCache.themeIdentity(for: updatedThoughtTheme)
            listView.reloadData()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        autoScrollTolerance = config.autoScrollTolerance

        listView.delegate = self
        listView.adapter = self
        listView.backgroundColor = .clear
        listView.alwaysBounceVertical = true
        listView.alwaysBounceHorizontal = false
        listView.showsVerticalScrollIndicator = true
        listView.showsHorizontalScrollIndicator = false
        listView.contentInsetAdjustmentBehavior = .never

        addSubview(listView)
        listView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        mermaidObserver = NotificationCenter.default.addObserver(
            forName: MermaidRenderer.didFinishRenderingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMermaidRenderDidFinish()
        }

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: HighPerformanceChatListView, _) in
            self.handleMermaidRenderDidFinish()
        }
    }

    deinit {
        if let mermaidObserver {
            NotificationCenter.default.removeObserver(mermaidObserver)
        }
    }

    private func handleMermaidRenderDidFinish() {
        guard rawEntries.contains(where: { $0.kind == .assistantMermaid }) else { return }
        mermaidRefreshSalt &+= 1
        let updated = visibleEntries(from: rawEntries)
        applyEntries(updated, animated: false, scrollToBottomAnimated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTheme(_ theme: MarkdownTheme) {
        self.theme = theme
    }

    func updateContentInsets(_ insets: UIEdgeInsets) {
        listView.contentInset = insets
        listView.scrollIndicatorInsets = insets
    }

    private func nextRenderGeneration() -> UInt64 {
        renderGenerationLock.lock()
        _renderGeneration &+= 1
        let value = _renderGeneration
        renderGenerationLock.unlock()
        return value
    }

    private func isCurrentRenderGeneration(_ generation: UInt64) -> Bool {
        renderGenerationLock.lock()
        let current = _renderGeneration
        renderGenerationLock.unlock()
        return current == generation
    }

    func render(
        messages: [ChatMessage],
        liveStatusText: String? = nil,
        failedDeliveryMessageIds: Set<UUID> = [],
        animated: Bool = true,
        scrollToBottomAnimated: Bool? = nil
    ) {
        let scrollToBottomAnimated = scrollToBottomAnimated ?? animated
        let generation = nextRenderGeneration()
        let theme = self.theme
        let themeIdentity = self.themeIdentity
        let thoughtTheme = self.thoughtTheme
        let thoughtThemeIdentity = self.thoughtThemeIdentity
        let expandedThoughtIdsSnapshot = self.expandedThoughtEntryIds
        let preprocessLinks = self.actionHandlers.onOpenLink != nil
        updateQueue.async { [weak self] in
            guard let self, self.isCurrentRenderGeneration(generation) else { return }
            let newEntries = mapper.entries(
                from: messages,
                liveStatusText: liveStatusText,
                failedDeliveryMessageIds: failedDeliveryMessageIds
            )
            guard self.isCurrentRenderGeneration(generation) else { return }

            for (idx, entry) in newEntries.enumerated() {
                if idx & 15 == 15, !self.isCurrentRenderGeneration(generation) {
                    return
                }
                guard !entry.text.isEmpty else { continue }
                let shouldPrewarm: Bool
                let entryTheme: MarkdownTheme
                let entryThemeId: Int
                switch entry.kind {
                case .assistantMarkdown, .assistantPlan:
                    shouldPrewarm = true
                    entryTheme = theme
                    entryThemeId = themeIdentity
                case .assistantThought:
                    shouldPrewarm = entry.isStreaming || expandedThoughtIdsSnapshot.contains(entry.id)
                    entryTheme = thoughtTheme
                    entryThemeId = thoughtThemeIdentity
                default:
                    shouldPrewarm = false
                    entryTheme = theme
                    entryThemeId = themeIdentity
                }
                if shouldPrewarm {
                    _ = markdownCache.package(
                        for: entry.id,
                        content: entry.text,
                        theme: entryTheme,
                        themeIdentity: entryThemeId,
                        preprocessPathLinks: preprocessLinks
                    )
                }
            }

            guard self.isCurrentRenderGeneration(generation) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentRenderGeneration(generation) else { return }
                self.rawEntries = newEntries
                self.pruneExpandedThoughtState(using: newEntries)
                let visibleEntries = self.visibleEntries(from: newEntries)
                let diff = ChatRenderDiff.make(old: self.renderedEntries, new: visibleEntries)
                if diff.isEmpty {
                    self.flushPendingEntriesIfPossible()
                    return
                }
                self.applyEntries(
                    visibleEntries,
                    animated: animated,
                    scrollToBottomAnimated: scrollToBottomAnimated
                )
            }
        }
    }

    func scrollToBottom(animated: Bool = true) {
        let target = listView.maximumContentOffset
        if abs(listView.contentOffset.y - target.y) <= 0.5 {
            isAutoScrollingToBottom = true
            reportAtBottomIfChanged(true)
            return
        }
        if animated {
            listView.scroll(to: target)
        } else {
            listView.setContentOffset(target, animated: false)
        }
        isAutoScrollingToBottom = true
        reportAtBottomIfChanged(true)
    }

    private func updateAutoScrollingFromCurrentOffset() {
        let isNearBottom = isContentOffsetNearBottom()
        if isNearBottom {
            isAutoScrollingToBottom = true
        }
        reportAtBottomIfChanged(isNearBottom)
        flushPendingEntriesIfPossible()
    }

    private func isContentOffsetNearBottom() -> Bool {
        abs(listView.contentOffset.y - listView.maximumContentOffset.y) <= autoScrollTolerance
    }

    private func reportAtBottomIfChanged(_ isAtBottom: Bool) {
        guard lastReportedAtBottom != isAtBottom else { return }
        lastReportedAtBottom = isAtBottom
        onAtBottomChanged?(isAtBottom)
    }

    private func isThoughtExpanded(for entry: ChatEntry) -> Bool {
        entry.isStreaming || expandedThoughtEntryIds.contains(entry.id)
    }

    private func pruneExpandedThoughtState(using entries: [ChatEntry]) {
        let validIds = Set(entries.lazy.filter { $0.kind == .assistantThought }.map(\.id))
        expandedThoughtEntryIds.formIntersection(validIds)
    }

    private func visibleEntries(from rawEntries: [ChatEntry]) -> [ChatEntry] {
        rawEntries.map { entry in
            switch entry.kind {
            case .assistantThought:
                let expanded = isThoughtExpanded(for: entry)
                if expanded {
                    return entry.withContentHashSalt(Self.thoughtExpandedHashSalt)
                }
                return entry
            case .assistantMermaid:
                if mermaidRefreshSalt != 0 {
                    return entry.withContentHashSalt(mermaidRefreshSalt)
                }
                return entry
            default:
                return entry
            }
        }
    }

    private func toggleThoughtExpansion(entryId: String) {
        guard let entry = rawEntries.first(where: { $0.id == entryId && $0.kind == .assistantThought }) else {
            return
        }
        guard !entry.isStreaming else { return }

        if expandedThoughtEntryIds.contains(entryId) {
            expandedThoughtEntryIds.remove(entryId)
        } else {
            expandedThoughtEntryIds.insert(entryId)
        }

        let visibleEntries = visibleEntries(from: rawEntries)
        let diff = ChatRenderDiff.make(old: renderedEntries, new: visibleEntries)
        guard !diff.isEmpty else { return }
        applyEntries(
            visibleEntries,
            animated: true,
            scrollToBottomAnimated: true
        )
    }

    private func applyEntries(
        _ visibleEntries: [ChatEntry],
        animated: Bool,
        scrollToBottomAnimated: Bool
    ) {
        if shouldDeferEntriesApplication() {
            pendingEntries = visibleEntries
            pendingEntriesAnimated = pendingEntriesAnimated || animated
            pendingScrollToBottomAnimated = pendingScrollToBottomAnimated || scrollToBottomAnimated
            return
        }

        pendingEntries = nil
        pendingEntriesAnimated = false
        pendingScrollToBottomAnimated = false
        renderedEntries = visibleEntries
        entries = visibleEntries
        dataSource.applySnapshot(using: visibleEntries, animatingDifferences: animated)
        if isAutoScrollingToBottom {
            scrollToBottom(animated: scrollToBottomAnimated)
        }
    }

    private func shouldDeferEntriesApplication() -> Bool {
        if isAutoScrollingToBottom {
            return false
        }
        return listView.isTracking || listView.isDragging || listView.isDecelerating
    }

    private func flushPendingEntriesIfPossible() {
        guard !shouldDeferEntriesApplication() else { return }
        guard let pendingEntries else { return }
        let animated = pendingEntriesAnimated
        let scrollToBottomAnimated = pendingScrollToBottomAnimated
        self.pendingEntries = nil
        pendingEntriesAnimated = false
        pendingScrollToBottomAnimated = false

        let diff = ChatRenderDiff.make(old: renderedEntries, new: pendingEntries)
        guard !diff.isEmpty else { return }

        renderedEntries = pendingEntries
        entries = pendingEntries
        dataSource.applySnapshot(using: pendingEntries, animatingDifferences: animated)
        if isAutoScrollingToBottom {
            scrollToBottom(animated: scrollToBottomAnimated)
        }
    }

    private func boundingHeight(for text: String, font: UIFont, width: CGFloat, lineLimit: Int = 0) -> CGFloat {
        ChatTextMetrics.measureSize(for: text, font: font, maxWidth: width, lineLimit: lineLimit).height
    }

    private static func makeThoughtMarkdownTheme(from baseTheme: MarkdownTheme) -> MarkdownTheme {
        var thoughtTheme = baseTheme
        let thoughtBodyFont = baseTheme.fonts.footnote.withWeight(.medium)
        thoughtTheme.align(to: thoughtBodyFont.pointSize)
        thoughtTheme.fonts.body = thoughtBodyFont
        thoughtTheme.fonts.bold = thoughtBodyFont
        thoughtTheme.fonts.italic = thoughtBodyFont
        thoughtTheme.fonts.footnote = thoughtBodyFont
        thoughtTheme.fonts.codeInline = UIFont.monospacedSystemFont(ofSize: thoughtBodyFont.pointSize, weight: .medium)
        thoughtTheme.fonts.code = UIFont.monospacedSystemFont(
            ofSize: ceil(thoughtBodyFont.pointSize * MarkdownTheme.codeScale),
            weight: .medium
        )
        return thoughtTheme
    }
}

extension HighPerformanceChatListView: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isAutoScrollingToBottom = false
        reportAtBottomIfChanged(false)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateAutoScrollingFromCurrentOffset()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateAutoScrollingFromCurrentOffset()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportAtBottomIfChanged(isContentOffsetNearBottom())
    }
}

extension HighPerformanceChatListView: ListViewAdapter {
    func listView(_ listView: ListViewKit.ListView, rowKindFor item: ItemType, at index: Int) -> RowKind {
        guard let entry = item as? ChatEntry else {
            assertionFailure("Unexpected item type")
            return RowType.system
        }

        switch entry.kind {
        case .userText:
            return RowType.userText
        case .userImages:
            return RowType.userImages
        case .assistantMarkdown:
            return RowType.assistantMarkdown
        case .assistantThought:
            return RowType.assistantThought
        case .assistantPlan:
            return RowType.assistantPlan
        case .assistantMermaid:
            return RowType.assistantMermaid
        case .toolCall:
            return RowType.toolCall
        case .fileChanges:
            return RowType.fileChanges
        case .system:
            return RowType.system
        case .error:
            return RowType.error
        case .streamingIndicator:
            return RowType.streaming
        }
    }

    func listViewMakeRow(for kind: RowKind) -> ListViewKit.ListRowView {
        guard let kind = kind as? RowType else {
            return ListRowView()
        }

        switch kind {
        case .userText:
            return UserTextRowView()
        case .userImages:
            return UserImagesRowView()
        case .assistantMarkdown:
            return MarkdownRowView(style: .assistant)
        case .assistantThought:
            return ThoughtRowView()
        case .assistantPlan:
            return MarkdownRowView(style: .plan)
        case .assistantMermaid:
            return MermaidRowView()
        case .toolCall:
            return ToolCallRowView()
        case .fileChanges:
            return FileChangesRowView()
        case .system:
            return SystemRowView(isError: false)
        case .error:
            return SystemRowView(isError: true)
        case .streaming:
            return StreamingIndicatorRowView()
        }
    }

    func listView(_ listView: ListViewKit.ListView, heightFor item: ItemType, at index: Int) -> CGFloat {
        guard let entry = item as? ChatEntry else {
            return 44
        }

        let width = max(0, listView.bounds.width - Self.rowInsets.left - Self.rowInsets.right)
        if width <= 0 {
            return 0
        }

        if entry.kind == .assistantMermaid {
            // Never store placeholder 160pt in ChatHeightCache.shared (AC-603);
            // dynamically measure from MermaidRenderer.shared cached outcome & appearance.
            let isDark = (traitCollection.userInterfaceStyle == .dark)
            let outcome = MermaidRenderer.shared.cachedOutcome(source: entry.text, isDark: isDark)
            let rowHeight = MermaidRowView.measureHeight(
                source: entry.text,
                outcome: outcome,
                contentWidth: width
            )
            return rowHeight + Self.rowInsets.bottom
        }

        if let cached = heightCache.height(for: entry, width: width) {
            return cached
        }

        let preprocessLinks = actionHandlers.onOpenLink != nil
        let height: CGFloat
        switch entry.kind {
        case .userText:
            let maxBubbleWidth = UserTextRowView.maxBubbleWidth(
                for: width,
                showsRetryButton: entry.showsRetryButton
            )
            let textWidth = max(0, maxBubbleWidth - 20)
            let textHeight = boundingHeight(for: entry.text, font: .preferredFont(forTextStyle: .callout), width: textWidth)
            let bubbleHeight = textHeight + 14
            height = entry.showsRetryButton ? max(bubbleHeight, UserTextRowView.retryButtonSize) : bubbleHeight

        case .userImages:
            height = 80

        case .assistantMarkdown:
            if sizingMarkdownView.theme != theme {
                sizingMarkdownView.theme = theme
            }
            let package = markdownCache.package(
                for: entry.id,
                content: entry.text,
                theme: theme,
                themeIdentity: themeIdentity,
                preprocessPathLinks: preprocessLinks
            )
            sizingMarkdownView.setMarkdownManually(package)
            let markdownWidth = max(0, width - (MarkdownStyle.assistant.horizontalPadding * 2))
            let size = sizingMarkdownView.boundingSize(for: markdownWidth)
            height = ceil(size.height) + (MarkdownStyle.assistant.verticalPadding * 2)

        case .assistantPlan:
            if sizingMarkdownView.theme != theme {
                sizingMarkdownView.theme = theme
            }
            let package = markdownCache.package(
                for: entry.id,
                content: entry.text,
                theme: theme,
                themeIdentity: themeIdentity,
                preprocessPathLinks: preprocessLinks
            )
            sizingMarkdownView.setMarkdownManually(package)
            let markdownWidth = max(0, width - (MarkdownStyle.plan.horizontalPadding * 2))
            let size = sizingMarkdownView.boundingSize(for: markdownWidth)
            height = ceil(size.height) + (MarkdownStyle.plan.verticalPadding * 2)

        case .assistantThought:
            let isExpanded = isThoughtExpanded(for: entry)
            if isExpanded {
                if sizingMarkdownView.theme != thoughtTheme {
                    sizingMarkdownView.theme = thoughtTheme
                }
                let package = markdownCache.package(
                    for: entry.id,
                    content: entry.text,
                    theme: thoughtTheme,
                    themeIdentity: thoughtThemeIdentity,
                    preprocessPathLinks: preprocessLinks
                )
                sizingMarkdownView.setMarkdownManually(package)
                let markdownWidth = max(0, width - (ThoughtRowView.horizontalPadding * 2))
                let markdownSize = sizingMarkdownView.boundingSize(for: markdownWidth)
                height = ThoughtRowView.collapsedHeight + ThoughtRowView.contentSpacing + ceil(markdownSize.height) + ThoughtRowView.bottomPadding
            } else {
                height = ThoughtRowView.collapsedHeight
            }

        case .assistantMermaid:
            height = MermaidRowView.placeholderHeight

        case .toolCall:
            let payload = ToolCallRowView.Payload(entry: entry)
            height = ToolCallRowView.estimatedHeight(for: payload, width: width)

        case .fileChanges:
            height = FileChangesRowView.estimatedHeight(for: entry.fileChanges, width: width)

        case .system, .error:
            height = SystemRowView.estimatedHeight(for: entry.text, width: width)

        case .streamingIndicator:
            height = 34
        }

        let finalHeight = height + Self.rowInsets.bottom
        heightCache.store(height: finalHeight, for: entry, width: width)
        return finalHeight
    }

    func listView(_ listView: ListViewKit.ListView, configureRowView rowView: ListViewKit.ListRowView, for item: ItemType, at index: Int) {
        guard let entry = item as? ChatEntry else {
            return
        }

        switch rowView {
        case let row as UserTextRowView:
            row.configure(
                text: entry.text,
                messageId: entry.messageId,
                showsRetryButton: entry.showsRetryButton,
                onRetry: actionHandlers.onRetryFailedMessage
            )

        case let row as UserImagesRowView:
            row.configure(
                images: entry.images,
                messageId: entry.messageId,
                showsRetryButton: entry.showsRetryButton,
                onRetry: actionHandlers.onRetryFailedMessage
            )

        case let row as MarkdownRowView:
            let preprocessLinks = actionHandlers.onOpenLink != nil
            let package = markdownCache.package(
                for: entry.id,
                content: entry.text,
                theme: theme,
                themeIdentity: themeIdentity,
                preprocessPathLinks: preprocessLinks
            )
            row.setMarkdown(
                package,
                renderToken: "\(entry.id)#\(entry.contentHash)",
                accessibleText: entry.text,
                onOpenLink: actionHandlers.onOpenLink
            )

        case let row as ThoughtRowView:
            let preprocessLinks = actionHandlers.onOpenLink != nil
            let isExpanded = isThoughtExpanded(for: entry)
            let package = isExpanded
                ? markdownCache.package(
                    for: entry.id,
                    content: entry.text,
                    theme: thoughtTheme,
                    themeIdentity: thoughtThemeIdentity,
                    preprocessPathLinks: preprocessLinks
                )
                : nil
            row.configure(
                markdown: package,
                theme: thoughtTheme,
                renderToken: "\(entry.id)#\(entry.contentHash)",
                isExpanded: isExpanded,
                isStreaming: entry.isStreaming,
                onToggle: { [weak self] in
                    self?.toggleThoughtExpansion(entryId: entry.id)
                },
                onOpenLink: actionHandlers.onOpenLink
            )

        case let row as MermaidRowView:
            row.configure(
                source: entry.text,
                renderToken: "\(entry.id)#\(entry.contentHash)",
                onOpenFullscreen: actionHandlers.onOpenMermaidFullscreen
            )

        case let row as ToolCallRowView:
            let payload = ToolCallRowView.Payload(entry: entry)
            row.configure(
                payload: payload,
                onACPPermission: { [weak self] requestId, optionId in
                    self?.actionHandlers.onACPPermissionResponse?(requestId, optionId)
                }
            )

        case let row as FileChangesRowView:
            row.configure(
                items: entry.fileChanges,
                onUndo: { [weak self] in
                    self?.actionHandlers.onUndoFileChanges?()
                },
                onReview: { [weak self] items in
                    self?.actionHandlers.onReviewFileChanges?(items)
                }
            )

        case let row as SystemRowView:
            row.text = entry.text

        case let row as StreamingIndicatorRowView:
            row.text = entry.text

        default:
            break
        }
    }
}
#endif
