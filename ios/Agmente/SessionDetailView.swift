import SwiftUI
import PhotosUI
import Photos
import ACPClient
import ACP

struct SessionDetailView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var serverViewModel: ServerViewModel
    @ObservedObject var sessionViewModel: ACPSessionViewModel
    @FocusState var isTextEditorFocused: Bool
    @State var textEditorWidth: CGFloat = 0
    @State var showingWorkingDirectoryPicker = false
    @State var showingImagePicker = false
    @State var selectedPhotoItems: [PhotosPickerItem] = []
    @State var showPhotoPermissionAlert = false
    @State private var showDeleteSessionConfirm = false
    @State private var showRemoteDeleteConfirm = false
    @State private var remoteDeleteTargetSessionId: String = ""
    @State private var remoteDeleteSubagentCount: Int? = nil
    @State private var isPreparingRemoteDelete = false
    @State private var isDeletingRemoteSession = false
    @State private var showDeleteErrorAlert = false
    @State private var deleteErrorMessage: String = ""
    @State private var showRenameSessionAlert = false
    @State private var renameTargetSessionId: String = ""
    @State private var renameTitleDraft: String = ""
    @State private var showRenameErrorAlert = false
    @State private var renameErrorMessage: String = ""
    @State private var isRenamingSession = false
    @State private var expandedThoughts: Set<UUID> = []
    @State private var showFileChangesReview = false
    @State private var fileChangesForReview: [FileChangeSummaryItem] = []
    @State private var showUndoUnavailableAlert = false
    @State private var transcriptState = ChatTranscriptState()
    @State private var scrollViewHeight: CGFloat = 0
    @State private var isAtBottom = true
    @State private var composerHeight: CGFloat = 0
    @State private var scrollToBottomAction: (() -> Void)?
    @State private var scrollPosition: UUID?
    @State var promptSelection: TextSelection?
    @State var lastValidCursorUTF16Offset: Int?
    @State var dismissedSlashOffset: Int?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: SessionSheetDestination?
    @State private var showLinkOfflineAlert = false

    private var mermaidSVGProvider: ((String, Bool) async -> Result<String, Error>)? {
        return { source, isDark in
            let result = await MermaidRenderer.shared.render(source: source, isDark: isDark)
            switch result {
            case .success(let diagram):
                return .success(diagram.svg)
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    private func handleChatLinkTap(_ raw: String) {
        let resolution = ChatLinkRouter.resolve(
            rawLink: raw,
            sessionCwd: model.currentSessionCwd(for: serverViewModel.id, sessionId: serverViewModel.sessionId),
            serverDefaultCwd: serverViewModel.workingDirectory
        )
        switch resolution {
        case .externalURL(let url):
            openURL(url)
        case .remotePath(let resolvedPath, let prefersDirectory, _, _):
            guard serverViewModel.connectionState == .connected else {
                showLinkOfflineAlert = true
                return
            }
            activeSheet = .remotePath(
                id: UUID(),
                initialPath: resolvedPath,
                prefersDirectory: prefersDirectory,
                lineAnchorHint: resolution.localizedLineAnchorHint,
                projectPath: model.normalizedSessionDirectoryForBrowsing(for: serverViewModel.id, sessionId: serverViewModel.sessionId)
            )
        case .ignored:
            break
        }
    }

    private func handleAssistantOpenURL(_ url: URL) -> OpenURLAction.Result {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" || scheme == "mailto" {
            return .systemAction
        }
        handleChatLinkTap(url.absoluteString)
        return .handled
    }

    @ViewBuilder
    private func sessionSheetContent(for destination: SessionSheetDestination) -> some View {
        switch destination {
        case .sessionInfo(let targetSessionId):
            let summary = serverViewModel.sessionSummaries.first(where: { $0.id == targetSessionId })
            SessionInfoSheet(
                model: model,
                sessionId: targetSessionId,
                localTitle: summary?.title,
                localCwd: summary?.cwd ?? model.currentSessionCwd(for: serverViewModel.id, sessionId: targetSessionId),
                serverId: serverViewModel.id
            )
        case .directoryBrowser(let path, let projectPath):
            RemoteFileBrowserSheet(
                initialPath: path,
                projectPath: projectPath,
                serverDefaultPath: model.normalizedDefaultDirectoryForBrowsing(for: serverViewModel.id),
                listDirectory: { params in
                    try await model.listRemoteDirectory(serverId: serverViewModel.id, params: params)
                },
                readFile: { filePath in
                    try await model.readRemoteFile(serverId: serverViewModel.id, path: filePath)
                },
                mermaidSVGProvider: mermaidSVGProvider
            )
        case .remotePath(_, let initialPath, let prefersDirectory, let lineAnchorHint, let projectPath):
            RemotePathSheetContainer(
                initialPath: initialPath,
                prefersDirectory: prefersDirectory,
                lineAnchorHint: lineAnchorHint,
                projectPath: projectPath,
                serverDefaultPath: model.normalizedDefaultDirectoryForBrowsing(for: serverViewModel.id),
                listDirectory: { params in
                    try await model.listRemoteDirectory(serverId: serverViewModel.id, params: params)
                },
                readFile: { filePath in
                    try await model.readRemoteFile(serverId: serverViewModel.id, path: filePath)
                },
                mermaidSVGProvider: mermaidSVGProvider
            )
        case .mermaidFullscreen(let source):
            MermaidFullscreenSheet(source: source)
        }
    }

    var body: some View {
        ZStack {
            Color(.systemGray6)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                transcriptContent
                    .frame(maxHeight: .infinity)

                composer
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { composerHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, newValue in
                                    composerHeight = newValue
                                }
                        }
                    )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if shouldShowScrollToBottomButton {
                Button(action: scrollTranscriptToBottom) {
                    if #available(iOS 26, *) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(12)
                            .glassEffect(.regular.interactive(), in: .circle)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, composerHeight + 24)
                .accessibilityLabel("Scroll to bottom")
                .zIndex(2)
            }
        }
        .overlay(alignment: .bottom) {
            if let slashToken = activeSlashToken,
               !visibleSlashCommands.isEmpty {
                VStack(spacing: 0) {
                    SlashCommandSuggestionsView(
                        commands: visibleSlashCommands,
                        dismissTokenOffset: slashToken.slashUTF16Offset,
                        onSelect: { command in
                            insertSlashCommand(command.name)
                        },
                        onDismiss: { slashOffset in
                            dismissedSlashOffset = slashOffset
                            isTextEditorFocused = true
                        }
                    )
                    Color.clear
                        .frame(height: composerHeight + 6)
                        .allowsHitTesting(false)
                }
                .padding(.top, 8)
                .padding(.horizontal, 12)
                .zIndex(3)
            }
        }
        .sheet(isPresented: $showingWorkingDirectoryPicker) {
            WorkingDirectoryPickerSheet(model: model, serverViewModel: serverViewModel, isPresented: $showingWorkingDirectoryPicker)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showFileChangesReview) {
            FileChangesReviewSheet(items: fileChangesForReview)
        }
        .sheet(item: $activeSheet, content: sessionSheetContent)
        .toolbar {
            let placement: ToolbarItemPlacement = .topBarTrailing
            // T5: Independent folder ToolbarItem outside `...` menu condition (covers both draft & materialized ACP sessions; AC-406 / AC-412)
            if serverViewModel.connectionState == .connected && !serverViewModel.sessionId.isEmpty {
                ToolbarItem(placement: placement) {
                    Button {
                        let cwd = model.normalizedSessionDirectoryForBrowsing(for: serverViewModel.id, sessionId: serverViewModel.sessionId)
                        activeSheet = .directoryBrowser(path: cwd, projectPath: cwd)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityIdentifier("acp-session-files-button")
                    .accessibilityLabel("Browse Server Files")
                }
            }

            let canViewSessionInfo = model.canViewSessionInfo(serverViewModel.sessionId, serverId: serverViewModel.id)
            let canRenameSession = !serverViewModel.isPendingSession
            let canReloadHistory = serverViewModel.canLoadSession() && !serverViewModel.isPendingSession
            let canDeleteRemoteSession = !serverViewModel.isPendingSession && serverViewModel.hasCompletedNonlocalSync
            if !serverViewModel.sessionId.isEmpty && (canViewSessionInfo || canRenameSession || canDeleteRemoteSession || canReloadHistory) {
                ToolbarItem(placement: placement) {
                    Menu {
                        if canViewSessionInfo {
                            Button {
                                activeSheet = .sessionInfo(sessionId: serverViewModel.sessionId)
                            } label: {
                                Label("Session Info", systemImage: "info.circle")
                            }
                            .accessibilityIdentifier("acp-session-info-menu-item")
                        }
                        if canRenameSession {
                            Button {
                                let targetId = serverViewModel.sessionId
                                renameTargetSessionId = targetId
                                renameTitleDraft = serverViewModel.sessionSummaries.first(where: { $0.id == targetId })?.title ?? ""
                                showRenameSessionAlert = true
                            } label: {
                                Label("Rename Session", systemImage: "pencil")
                            }
                            .disabled(serverViewModel.connectionState != .connected || isRenamingSession)
                            .accessibilityIdentifier("acp-session-rename-button")
                        }
                        if canReloadHistory {
                            Button {
                                serverViewModel.reloadSession(serverViewModel.sessionId)
                            } label: {
                                Label("Reload History", systemImage: "arrow.clockwise")
                            }
                            .disabled(serverViewModel.connectionState != .connected || serverViewModel.isStreaming)
                        }
                        if canDeleteRemoteSession {
                            Button(role: .destructive) {
                                let targetId = serverViewModel.sessionId
                                guard !targetId.isEmpty else { return }
                                if serverViewModel.isSessionRunning(targetId) || serverViewModel.isSessionWaitingForUser(targetId) {
                                    deleteErrorMessage = RemoteSessionDeleteError.activeSession.localizedMessage
                                    showDeleteErrorAlert = true
                                    return
                                }
                                guard !isPreparingRemoteDelete && !isDeletingRemoteSession else { return }
                                Task { @MainActor in
                                    isPreparingRemoteDelete = true
                                    defer { isPreparingRemoteDelete = false }
                                    let subagentCount = await model.fetchSessionInfoForDeleteConfirmation(
                                        serverId: serverViewModel.id,
                                        sessionId: targetId
                                    )
                                    remoteDeleteTargetSessionId = targetId
                                    remoteDeleteSubagentCount = subagentCount
                                    showRemoteDeleteConfirm = true
                                }
                            } label: {
                                Label("Delete Session", systemImage: "trash")
                            }
                            .disabled(serverViewModel.connectionState != .connected || isPreparingRemoteDelete || isDeletingRemoteSession)
                            .accessibilityIdentifier("acp-session-delete-button")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityIdentifier("acp-session-more-button")
                }
            }
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: $showDeleteSessionConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                let idToDelete = serverViewModel.sessionId
                guard !idToDelete.isEmpty else { return }
                model.deleteSession(serverId: serverViewModel.id, sessionId: idToDelete)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the session and its cached chat history from this device.")
        }
        .confirmationDialog(
            "Delete Session Permanently?",
            isPresented: $showRemoteDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                let targetId = remoteDeleteTargetSessionId
                guard !targetId.isEmpty else { return }
                Task { @MainActor in
                    isDeletingRemoteSession = true
                    defer { isDeletingRemoteSession = false }
                    let result = await model.deleteRemoteSession(
                        sessionId: targetId,
                        serverId: serverViewModel.id
                    )
                    switch result {
                    case .success:
                        dismiss()
                    case .failure(let error):
                        deleteErrorMessage = error.localizedMessage
                        showDeleteErrorAlert = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let count = remoteDeleteSubagentCount, count > 0 {
                Text("This will permanently delete this session and \(count) linked subagents on the host. This action cannot be undone.")
            } else {
                Text("This will permanently delete this session on the host. This action cannot be undone.")
            }
        }
        .alert("Delete Failed", isPresented: $showDeleteErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
        .alert("Undo not available", isPresented: $showUndoUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nonlocal can't undo file changes yet.")
        }
        .alert("Rename Session", isPresented: $showRenameSessionAlert) {
            TextField("New title (leave blank to reset)", text: $renameTitleDraft)
                .accessibilityIdentifier("rename-session-text-field")
            Button("Save") {
                let targetId = renameTargetSessionId
                let draft = renameTitleDraft
                Task { @MainActor in
                    isRenamingSession = true
                    defer { isRenamingSession = false }
                    do {
                        _ = try await model.renameSession(serverId: serverViewModel.id, sessionId: targetId, title: draft)
                    } catch {
                        renameErrorMessage = error.localizedDescription
                        showRenameErrorAlert = true
                    }
                }
            }
            .accessibilityIdentifier("rename-session-save-button")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Update the display title for this session.")
        }
        .alert("Rename Failed", isPresented: $showRenameErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameErrorMessage)
        }
        .alert("Server Not Connected", isPresented: $showLinkOfflineAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connect to the server before viewing remote files or directories.")
        }
    }
}

private extension SessionDetailView {
    @ViewBuilder
    var transcriptContent: some View {
        highPerformanceChatTranscript
    }

    func scrollTranscriptToBottom() {
        transcriptState.scrollToBottom(animated: true)
        transcriptState.isAtBottom = true
        isAtBottom = true
    }

    var chatTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sessionViewModel.chatMessages) { message in
                        chatBubble(for: message)
                            .id(message.id)
                    }
                    if let liveStatus = sessionViewModel.liveActivityStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !liveStatus.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(liveStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .id("acp-live-status-indicator")
                    }
                }
                .applyScrollTargetLayoutIfAvailable()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.horizontal, 12)
                .background(ChatContentMetricsReader())
            }
            .applyScrollPositionIfAvailable(id: $scrollPosition)
            .coordinateSpace(name: ChatScrollCoordinateSpace.name)
            .background(ChatScrollViewHeightReader())
            .onAppear {
                isAtBottom = true
                scrollToLastMessage(proxy: proxy, animated: false)
            }
            .onChange(of: serverViewModel.sessionId) { _, _ in
                isAtBottom = true
                resetSlashAutocompleteState()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    scrollToLastMessage(proxy: proxy, animated: false)
                }
            }
            .onChange(of: sessionViewModel.chatMessages.count) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    scrollToLastMessageIfPinned(proxy: proxy, animated: true)
                }
            }
            .onChange(of: sessionViewModel.chatMessages.last?.content) { _, _ in
                scrollToLastMessageIfPinned(proxy: proxy, animated: false)
            }
            .onChange(of: sessionViewModel.chatMessages.last?.segments.count) { _, _ in
                scrollToLastMessageIfPinned(proxy: proxy, animated: false)
            }
            .onChange(of: isTextEditorFocused) { _, focused in
                if focused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        scrollToLastMessageIfPinned(proxy: proxy, animated: true)
                    }
                }
            }
            .onChatScrollViewHeightChange { height in
                scrollViewHeight = height
            }
            .onChatContentMetricsChange { metrics in
                if #available(iOS 17.0, *) {
                    return
                }
                updateIsAtBottom(contentHeight: metrics.height, contentMinY: metrics.minY)
            }
            .onChange(of: scrollPosition) { newValue in
                guard let lastId = sessionViewModel.chatMessages.last?.id else {
                    isAtBottom = true
                    return
                }
                isAtBottom = (newValue == lastId)
            }
            .id(serverViewModel.sessionId) // Reset scroll state when session changes
            .overlay(alignment: .top) {
                if sessionViewModel.chatMessages.isEmpty {
                    if serverViewModel.pendingSessionLoad == serverViewModel.sessionId {
                        ProgressView("Loading session...")
                            .padding(.top, 60)
                    } else {
                        VStack(spacing: 12) {
                            PixelBot()
                            Text("let's git together and code")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                    }
                }
            }
            .onAppear {
                scrollToBottomAction = { scrollToLastMessage(proxy: proxy, animated: true) }
            }
        }
    }

    private func scrollToLastMessage(proxy: ScrollViewProxy, animated: Bool) {
        guard let lastMessage = sessionViewModel.chatMessages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }

    private func scrollToLastMessageIfPinned(proxy: ScrollViewProxy, animated: Bool) {
        guard isAtBottom else { return }
        scrollToLastMessage(proxy: proxy, animated: animated)
    }

    private func updateIsAtBottom(contentHeight: CGFloat, contentMinY: CGFloat) {
        guard scrollViewHeight > 0, contentHeight > 0 else { return }
        let threshold: CGFloat = 80
        let distanceFromBottom = contentHeight + contentMinY - scrollViewHeight
        let atBottom = distanceFromBottom <= threshold
        if isAtBottom != atBottom {
            isAtBottom = atBottom
        }
    }

    private var shouldShowScrollToBottomButton: Bool {
        !isAtBottom && !sessionViewModel.chatMessages.isEmpty && visibleSlashCommands.isEmpty
    }

    var highPerformanceChatTranscript: some View {
        ChatTranscriptContainerView(
            state: transcriptState,
            messages: sessionViewModel.chatMessages,
            liveStatusText: sessionViewModel.liveActivityStatus,
            failedDeliveryMessageIds: sessionViewModel.failedDeliveryMessageIds,
            contentInsets: .zero,
            actionHandlers: ChatEntryActionHandlers(
                onACPPermissionResponse: { requestId, optionId in
                    serverViewModel.sendPermissionResponse(requestId: requestId, optionId: optionId)
                },
                onUndoFileChanges: {
                    showUndoUnavailableAlert = true
                },
                onReviewFileChanges: { items in
                    guard !items.isEmpty else { return }
                    fileChangesForReview = items
                    showFileChangesReview = true
                },
                onOpenLink: { raw in
                    handleChatLinkTap(raw)
                },
                onOpenMermaidFullscreen: { source in
                    activeSheet = .mermaidFullscreen(source: source)
                }
            ),
            onAtBottomChanged: { value in
                isAtBottom = value
            },
            onRetryFailedMessage: { msgId in
                sessionViewModel.restoreFailedDelivery(for: msgId)
            }
        )
        .overlay(alignment: .top) {
            if sessionViewModel.chatMessages.isEmpty {
                if serverViewModel.pendingSessionLoad == serverViewModel.sessionId {
                    ProgressView("Loading session...")
                        .padding(.top, 60)
                } else {
                    VStack(spacing: 12) {
                        PixelBot()
                        Text("let's git together and code")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                }
            }
        }
        .onAppear {
            transcriptState.isAtBottom = true
            isAtBottom = true
        }
    }

    @ViewBuilder
    func chatBubble(for message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            userBubble(content: message.content, images: message.images)
        case .assistant:
            assistantBubble(message: message)
        case .system:
            if message.isError {
                errorBubble(content: message.content)
            } else {
                systemBubble(content: message.content)
            }
        }
    }

    func userBubble(content: String, images: [ChatImageData] = []) -> some View {
        UserBubble(content: content, images: images)
    }

    func assistantBubble(message: ChatMessage) -> some View {
        assistantContentView(message: message)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    func assistantContentView(message: ChatMessage) -> some View {
        let segments = displaySegments(for: message)
        let fileChangeSegments = segments.filter { FileChangeSummary.isFileChangeSegment($0) }
        let contentSegments = segments
            .filter { !FileChangeSummary.isFileChangeSegment($0) }
        let displaySegments = contentSegments.groupedThoughtSegments()
        let fileChangeItems = FileChangeSummary.items(from: fileChangeSegments)
        let lastIndex = displaySegments.indices.last

        VStack(alignment: .leading, spacing: 8) {
            if displaySegments.isEmpty && message.isStreaming {
                shimmeringBubble(text: String(localized: "Thinking…"))
            }

            ForEach(Array(displaySegments.enumerated()), id: \.element.id) { index, display in
                switch display {
                case .thoughtGroup(let group):
                    let text = group.combinedText
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        thoughtBubble(
                            text: text,
                            isStreaming: message.isStreaming && lastIndex == index,
                            isExpanded: expandedThoughts.contains(group.id)
                        ) {
                            toggleThoughtExpansion(for: group.id)
                        }
                    }
                case .message(let segment):
                    if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownText(content: ChatPathLinkPreprocessor.preprocess(segment.text))
                            .environment(\.openURL, OpenURLAction(handler: handleAssistantOpenURL))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                case .toolCall(let segment):
                    toolCallBubble(segment: segment, isStreaming: message.isStreaming && lastIndex == index)
                case .plan(let segment):
                    if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownText(content: ChatPathLinkPreprocessor.preprocess(segment.text))
                            .environment(\.openURL, OpenURLAction(handler: handleAssistantOpenURL))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            if !fileChangeItems.isEmpty {
                FileChangesSummaryView(
                    items: fileChangeItems,
                    onUndo: { showUndoUnavailableAlert = true },
                    onReview: {
                        fileChangesForReview = fileChangeItems
                        showFileChangesReview = true
                    }
                )
            }
        }
    }

    func displaySegments(for message: ChatMessage) -> [AssistantSegment] {
        if !message.segments.isEmpty {
            // Filter out empty message segments during display
            return message.segments.filter { segment in
                if segment.kind == .message || segment.kind == .thought {
                    return !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return true // Always show tool calls
            }
        }

        return parseAssistantContent(message.content).compactMap { segment in
            // Skip empty non-tool-call segments
            if !segment.isToolCall && segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            if segment.isToolCall {
                let parsed = parseToolCallDisplay(from: segment.text)
                return AssistantSegment(
                    kind: .toolCall,
                    text: parsed.title,
                    toolCall: parsed
                )
            }
            return AssistantSegment(kind: .message, text: segment.text)
        }
    }

    struct ContentSegment {
        let text: String
        let isToolCall: Bool
    }

    func parseAssistantContent(_ content: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        var currentText = ""

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("Tool call:") {
                // Save any accumulated text
                if !currentText.isEmpty {
                    segments.append(ContentSegment(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines), isToolCall: false))
                    currentText = ""
                }
                // Add tool call segment
                segments.append(ContentSegment(text: line, isToolCall: true))
            } else {
                if !currentText.isEmpty {
                    currentText += "\n"
                }
                currentText += line
            }
        }

        // Add remaining text
        if !currentText.isEmpty {
            segments.append(ContentSegment(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines), isToolCall: false))
        }

        return segments
    }

    func parseToolCallDisplay(from text: String) -> ToolCallDisplay {
        var displayContent = text
        if displayContent.hasPrefix("Tool call: ") {
            displayContent = String(displayContent.dropFirst("Tool call: ".count))
        }

        var toolKind: String? = nil
        if displayContent.hasPrefix("["), let endBracket = displayContent.firstIndex(of: "]") {
            toolKind = String(displayContent[displayContent.index(after: displayContent.startIndex)..<endBracket])
            displayContent = String(displayContent[displayContent.index(after: endBracket)...]).trimmingCharacters(in: .whitespaces)
        }

        var status: String? = nil
        if let statusStart = displayContent.lastIndex(of: "("),
           let statusEnd = displayContent.lastIndex(of: ")"),
           statusStart < statusEnd {
            status = String(displayContent[displayContent.index(after: statusStart)..<statusEnd])
            displayContent = String(displayContent[..<statusStart]).trimmingCharacters(in: .whitespaces)
        }

        return ToolCallDisplay(toolCallId: nil, title: displayContent, kind: toolKind, status: status)
    }

    func toolCallBubble(segment: AssistantSegment, isStreaming: Bool) -> some View {
        let displayContent = segment.toolCall?.title ?? segment.text.replacingOccurrences(of: "Tool call: ", with: "")
        let toolKind = segment.toolCall?.kind
        let status = segment.toolCall?.status
        let output = segment.toolCall?.output
        let permissionOptions = segment.toolCall?.permissionOptions
        let permissionRequestId = segment.toolCall?.acpPermissionRequestId

        let iconName = iconForToolKind(toolKind)
        let iconColor = colorForToolKind(toolKind)
        let isAwaitingPermission = status == "awaiting_permission" && permissionOptions != nil && !permissionOptions!.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: isAwaitingPermission ? "shield.lefthalf.filled" : iconName)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isAwaitingPermission ? .orange : iconColor)

                Text(displayContent)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer()

                // Show status indicator
                if isAwaitingPermission {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.orange)
                } else if isStreaming && (status == nil || status == "in_progress" || status == "pending") {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                } else if status == "completed" {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.green)
                } else if status == "failed" {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.red)
                }
            }

            // Show permission options if awaiting permission
            if isAwaitingPermission, let options = permissionOptions, let requestId = permissionRequestId {
                permissionOptionsView(options: options, requestId: requestId)
            }

            // Show output if present
            if let output, !output.isEmpty {
                let displayOutput = output.truncatedToolOutput(maxLines: 6, maxChars: 1_200)
                Text(displayOutput)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isAwaitingPermission ? Color.orange.opacity(0.1) : iconColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isAwaitingPermission ? Color.orange.opacity(0.5) : iconColor.opacity(0.3), lineWidth: isAwaitingPermission ? 2 : 1)
        )
    }

    func permissionOptionsView(options: [ACPPermissionOption], requestId: ACP.ID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permission required")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 4)

            HStack(spacing: 8) {
                ForEach(options, id: \.optionId) { option in
                    Button {
                        serverViewModel.sendPermissionResponse(requestId: requestId, optionId: option.optionId)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: iconForPermissionKind(option.kind))
                                .font(.system(size: 17, weight: .regular))
                            Text(option.name.truncatedLabel(maxChars: 24))
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(backgroundForPermissionKind(option.kind))
                        .foregroundStyle(foregroundForPermissionKind(option.kind))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func iconForPermissionKind(_ kind: ACPPermissionOptionKind) -> String {
        switch kind {
        case .allowOnce, .allowAlways:
            return "checkmark.circle"
        case .rejectOnce, .rejectAlways:
            return "xmark.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    func backgroundForPermissionKind(_ kind: ACPPermissionOptionKind) -> Color {
        switch kind {
        case .allowOnce, .allowAlways:
            return Color(uiColor: UIColor { traitCollection in
                if traitCollection.userInterfaceStyle == .dark {
                    return UIColor(red: 44.0 / 255.0, green: 82.0 / 255.0, blue: 55.0 / 255.0, alpha: 1)
                }
                return UIColor(red: 210.0 / 255.0, green: 239.0 / 255.0, blue: 219.0 / 255.0, alpha: 1)
            })
        case .rejectOnce, .rejectAlways:
            return Color(uiColor: UIColor { traitCollection in
                if traitCollection.userInterfaceStyle == .dark {
                    return UIColor(red: 92.0 / 255.0, green: 54.0 / 255.0, blue: 56.0 / 255.0, alpha: 1)
                }
                return UIColor(red: 245.0 / 255.0, green: 221.0 / 255.0, blue: 220.0 / 255.0, alpha: 1)
            })
        case .unknown:
            return Color.gray.opacity(0.15)
        }
    }

    func foregroundForPermissionKind(_ kind: ACPPermissionOptionKind) -> Color {
        switch kind {
        case .allowOnce, .allowAlways:
            return Color(uiColor: UIColor { traitCollection in
                if traitCollection.userInterfaceStyle == .dark {
                    return UIColor(red: 92.0 / 255.0, green: 214.0 / 255.0, blue: 129.0 / 255.0, alpha: 1)
                }
                return UIColor(red: 38.0 / 255.0, green: 150.0 / 255.0, blue: 71.0 / 255.0, alpha: 1)
            })
        case .rejectOnce, .rejectAlways:
            return Color(uiColor: UIColor { traitCollection in
                if traitCollection.userInterfaceStyle == .dark {
                    return UIColor(red: 255.0 / 255.0, green: 109.0 / 255.0, blue: 107.0 / 255.0, alpha: 1)
                }
                return UIColor(red: 198.0 / 255.0, green: 46.0 / 255.0, blue: 56.0 / 255.0, alpha: 1)
            })
        case .unknown:
            return .primary
        }
    }


    func thoughtBubble(text: String, isStreaming: Bool, isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        let lineCount = text.components(separatedBy: "\n").count
        let shouldTruncate = text.count > 240 || lineCount > 5

        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(content: ChatPathLinkPreprocessor.preprocess(text), font: .caption)
                    .environment(\.openURL, OpenURLAction(handler: handleAssistantOpenURL))
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded || !shouldTruncate ? nil : 6)

                if shouldTruncate {
                    Button(action: toggle) {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderless)
                }
            }

            Spacer()

            if isStreaming {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func toggleThoughtExpansion(for id: UUID) {
        if expandedThoughts.contains(id) {
            expandedThoughts.remove(id)
        } else {
            expandedThoughts.insert(id)
        }
    }

    func iconForToolKind(_ kind: String?) -> String {
        switch kind {
        case "read": return "doc.text.magnifyingglass"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "think": return "brain"
        case "fetch": return "arrow.down.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    func colorForToolKind(_ kind: String?) -> Color {
        switch kind {
        case "read": return .blue
        case "edit": return .orange
        case "delete": return .red
        case "execute": return .purple
        case "search": return .green
        case "think": return .indigo
        case "fetch": return .cyan
        default: return .orange
        }
    }

    func systemBubble(content: String) -> some View {
        SystemBubble(content: content)
    }

    func errorBubble(content: String) -> some View {
        ErrorBubble(content: content)
    }

    func shimmeringBubble(text: String) -> some View {
        ShimmeringBubble(text: text)
    }

}
