import SwiftUI
import PhotosUI
import Photos
import ACPClient
import ACP

extension SessionDetailView {
    var textEditorHeight: CGFloat {
        let uiFont = UIFont.preferredFont(forTextStyle: .body)
        let sizingTextView = makeSizingTextView(font: uiFont)
        let baseHeight = uiFont.lineHeight + sizingTextView.textContainerInset.top + sizingTextView.textContainerInset.bottom

        guard textEditorWidth > 0 else {
            return min(110, ceil(baseHeight))
        }

        sizingTextView.text = sessionViewModel.promptText.isEmpty ? " " : sessionViewModel.promptText
        let size = sizingTextView.sizeThatFits(CGSize(width: textEditorWidth, height: .greatestFiniteMagnitude))
        return min(110, ceil(max(baseHeight, size.height)))
    }

    private var promptPlaceholderText: String {
        String(localized: "Message the agent…")
    }

    var activeSlashToken: SlashCommandToken? {
        guard isTextEditorFocused, !sessionViewModel.availableCommands.isEmpty else {
            return nil
        }
        let cursorOffset: Int?
        if let promptSelection {
            cursorOffset = SlashCommandAutocomplete.insertionUTF16Offset(
                in: sessionViewModel.promptText,
                from: promptSelection
            )
        } else {
            cursorOffset = lastValidCursorUTF16Offset ?? sessionViewModel.promptText.utf16.count
        }
        return SlashCommandAutocomplete.activeToken(
            in: sessionViewModel.promptText,
            utf16CursorOffset: cursorOffset
        )
    }

    var visibleSlashCommands: [SessionCommand] {
        guard let token = activeSlashToken,
              token.slashUTF16Offset != dismissedSlashOffset else {
            return []
        }
        return SlashCommandAutocomplete.filter(
            sessionViewModel.availableCommands,
            query: token.query
        )
    }

    func resetSlashAutocompleteState() {
        promptSelection = nil
        lastValidCursorUTF16Offset = nil
        dismissedSlashOffset = nil
    }

    func insertSlashCommand(_ name: String, restoreFocusAfterMenu: Bool = false) {
        let wasFocused = isTextEditorFocused
        let targetSessionId = serverViewModel.sessionId
        let text = sessionViewModel.promptText
        let cursorOffset = SlashCommandAutocomplete.selectionEndUTF16Offset(
            in: text,
            from: promptSelection
        ) ?? lastValidCursorUTF16Offset ?? text.utf16.count
        let token = SlashCommandAutocomplete.activeToken(
            in: text,
            utf16CursorOffset: cursorOffset
        )
        let result = SlashCommandAutocomplete.insertCommand(
            name,
            into: text,
            utf16CursorOffset: cursorOffset,
            replacing: token
        )
        let targetSelection = SlashCommandAutocomplete.selection(
            atUTF16Offset: result.cursorUTF16Offset,
            in: result.text
        )

        sessionViewModel.promptText = result.text
        promptSelection = targetSelection
        lastValidCursorUTF16Offset = result.cursorUTF16Offset
        dismissedSlashOffset = nil
        isTextEditorFocused = true

        let needsDelayedMenuRefocus = restoreFocusAfterMenu || !wasFocused
        Task { @MainActor in
            await Task.yield()
            guard serverViewModel.sessionId == targetSessionId,
                  sessionViewModel.promptText == result.text else {
                return
            }
            promptSelection = targetSelection
            isTextEditorFocused = true

            if needsDelayedMenuRefocus {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled,
                      serverViewModel.sessionId == targetSessionId,
                      sessionViewModel.promptText == result.text else {
                    return
                }
                if !isTextEditorFocused {
                    promptSelection = targetSelection
                    isTextEditorFocused = true
                }
            }
        }
    }

    private func makeSizingTextView(font: UIFont) -> UITextView {
        let textView = UITextView()
        textView.font = font
        textView.isScrollEnabled = false
        return textView
    }


    var composer: some View {
        let hasPrompt = !sessionViewModel.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !sessionViewModel.attachedImages.isEmpty
        let canSendPrompt = serverViewModel.connectionState == .connected
            && !serverViewModel.sessionId.isEmpty
            && !serverViewModel.isStreaming
            && (hasPrompt || hasImages)
        let canCancelPrompt = serverViewModel.isStreaming && !serverViewModel.sessionId.isEmpty

        let performSend = {
            guard canSendPrompt else { return }
            isTextEditorFocused = false

            let promptText = sessionViewModel.promptText
            let images = sessionViewModel.attachedImages

            // Only clear composer when submitPrompt accepts the message (preserve draft on validation failure)
            let accepted = serverViewModel.submitPrompt(
                promptText: promptText,
                images: images,
                commandName: nil
            )
            if accepted {
                sessionViewModel.promptText = ""
                sessionViewModel.clearImageAttachments()
                resetSlashAutocompleteState()
            }
        }
        let performCancel = {
            guard canCancelPrompt else { return }
            model.sendCancel(serverId: serverViewModel.id, sessionId: serverViewModel.sessionId)
        }

        return VStack(alignment: .leading, spacing: 8) {
            // Mode picker, model/config capsules, tools, and usage badge in one scrollable row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Mode picker (if modes available)
                    if !sessionViewModel.availableModes.isEmpty {
                        modePicker
                    }

                    ForEach(sessionViewModel.visibleConfigOptions(), id: \.id) { option in
                        configOptionControl(for: option)
                    }

                    // Working directory button
                    Button {
                        showingWorkingDirectoryPicker = true
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(model.currentSessionCwd(for: serverViewModel.id, sessionId: serverViewModel.sessionId).isEmpty ? .secondary : .primary)
                    }
                    .accessibilityIdentifier("acp-cwd-button")

                    if !sessionViewModel.availableCommands.isEmpty {
                        commandPicker
                    }

                    // Image attachment button
                    imageAttachmentButton

                    // Context-window usage / cost (shown once the agent reports it)
                    usageBadge
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
            .overlay(alignment: .trailing) {
                LinearGradient(
                    colors: [Color.clear, Color(.systemGray6).opacity(0.9)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 14)
                .allowsHitTesting(false)
            }
            .accessibilityIdentifier("acp-composer-toolbar")

            // Image attachment preview (if any images attached)
            if !sessionViewModel.attachedImages.isEmpty {
                imageAttachmentPreview
                    .padding(.horizontal, 10)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $sessionViewModel.promptText, selection: $promptSelection)
                        .focused($isTextEditorFocused)
                        .accessibilityIdentifier("acp-prompt-editor")
                        .onChange(of: promptSelection) { _, newSelection in
                            if let offset = SlashCommandAutocomplete.selectionEndUTF16Offset(
                                in: sessionViewModel.promptText,
                                from: newSelection
                            ) {
                                lastValidCursorUTF16Offset = offset
                            }
                        }
                        .onChange(of: sessionViewModel.promptText) { _, newText in
                            if newText.isEmpty {
                                resetSlashAutocompleteState()
                            }
                        }
                        .onChange(of: activeSlashToken) { _, newToken in
                            if newToken == nil || newToken?.slashUTF16Offset != dismissedSlashOffset {
                                dismissedSlashOffset = nil
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .frame(minHeight: 36, maxHeight: textEditorHeight)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { textEditorWidth = geo.size.width }
                                    .onChange(of: geo.size.width) { _, newWidth in
                                        textEditorWidth = newWidth
                                    }
                            }
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .font(.body)
                        .scrollContentBackground(.hidden)

                    if sessionViewModel.promptText.isEmpty && sessionViewModel.attachedImages.isEmpty {
                        Text(promptPlaceholderText)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(.systemGray4))
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    if serverViewModel.isStreaming {
                        performCancel()
                    } else {
                        performSend()
                    }
                } label: {
                    let isStreaming = serverViewModel.isStreaming
                    let isConnected = serverViewModel.connectionState == .connected
                    Image(systemName: isStreaming ? "stop.fill" : "paperplane.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(isStreaming ? Color.primary : Color.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isStreaming ? Color(.systemGray5) : (isConnected ? Color.black : Color.gray))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color(.systemGray3), lineWidth: isStreaming ? 1 : 0)
                        )
                }
                .disabled(!(canSendPrompt || canCancelPrompt))
                .buttonStyle(.plain)
                .accessibilityIdentifier("acp-send-button")
                .accessibilityValue(Text(verbatim: serverViewModel.isStreaming ? "stop" : "send"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .onChange(of: selectedPhotoItems) { _, newItems in
            Task {
                await loadSelectedPhotos(newItems)
                selectedPhotoItems = []
            }
        }
    }

    // MARK: - Slash Commands

    var commandPicker: some View {
        Menu {
            ForEach(sessionViewModel.availableCommands, id: \SessionCommand.id) { (command: SessionCommand) in
                Button {
                    insertSlashCommand(command.name, restoreFocusAfterMenu: true)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("/\(command.name)")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(command.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let hint = command.inputHint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .accessibilityIdentifier("acp-command-menu-\(command.name)")
            }
        } label: {
            Image(systemName: "slash.circle")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Color(.systemGray5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("acp-commands-button")
    }

    // MARK: - Image Attachment Button

    @ViewBuilder
    var imageAttachmentButton: some View {
        let supportsImages = sessionViewModel.supportsImageAttachment
        let canAttach = sessionViewModel.canAttachMoreImages
        let maxSelection = ImageProcessor.maxAttachments - sessionViewModel.attachedImages.count

        Button {
            Task {
                let granted = await requestPhotoLibraryAccess()
                await MainActor.run {
                    if granted {
                        showingImagePicker = true
                    } else {
                        showPhotoPermissionAlert = true
                    }
                }
            }
        } label: {
            Image(systemName: "photo")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(supportsImages ? Color(.systemGray5) : Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(supportsImages ? .primary : .quaternary)
        }
        .disabled(!canAttach)
        .accessibilityIdentifier("acp-image-button")
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: maxSelection,
            matching: .images,
            photoLibrary: .shared()
        )
        .alert("Allow Nonlocal to access your photos?", isPresented: $showPhotoPermissionAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    // MARK: - Image Attachment Preview

    var imageAttachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessionViewModel.attachedImages) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(platformImage: attachment.thumbnail())
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(.systemGray4), lineWidth: 1)
                            )

                        // Remove button
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                sessionViewModel.removeImageAttachment(attachment.id)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, Color(.systemGray))
                                .background(Circle().fill(Color(.systemBackground)).padding(2))
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Photo Loading

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard sessionViewModel.canAttachMoreImages else { break }

            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    _ = await MainActor.run {
                        sessionViewModel.addImageAttachment(image)
                    }
                }
            } catch {
            }
        }
    }

    private func requestPhotoLibraryAccess() async -> Bool {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch currentStatus {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        case .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }


    var modePicker: some View {
        Menu {
            let modes: [AgentModeOption] = sessionViewModel.availableModes
            ForEach(modes, id: \AgentModeOption.id) { (mode: AgentModeOption) in
                Button {
                    model.sendSetMode(mode.id, serverId: serverViewModel.id, sessionId: serverViewModel.sessionId)
                } label: {
                    HStack {
                        Text(mode.name)
                        if sessionViewModel.currentModeId == mode.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconForMode(sessionViewModel.currentModeId))
                    .font(.caption.weight(.semibold))
                Text(currentModeName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(colorForMode(sessionViewModel.currentModeId).opacity(0.15))
            .foregroundStyle(colorForMode(sessionViewModel.currentModeId))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("acp-mode-picker")
    }

    var currentModeName: String {
        if let modeId = sessionViewModel.currentModeId,
           let mode = sessionViewModel.availableModes.first(where: { $0.id == modeId }) {
            return mode.name
        }
        return sessionViewModel.availableModes.first?.name ?? "Mode"
    }

    /// Compact, read-only context-window usage / cost readout, driven by ACP `usage_update`.
    @ViewBuilder
    var usageBadge: some View {
        if let usage = sessionViewModel.usage {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.caption2.weight(.semibold))
                Text(usageLabel(usage))
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.systemGray5))
            .foregroundStyle(.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("acp-usage-badge")
            .accessibilityLabel(usageAccessibilityLabel(usage))
        }
    }

    private func usageLabel(_ usage: ACPUsageInfo) -> String {
        var parts: [String] = []
        if let fraction = usage.fraction {
            parts.append("\(Int((fraction * 100).rounded()))%")
        }
        if let cost = usage.cost {
            parts.append(formatUsageCost(cost))
        }
        if parts.isEmpty {
            parts.append("\(usage.used) tok")
        }
        return parts.joined(separator: " · ")
    }

    private func usageAccessibilityLabel(_ usage: ACPUsageInfo) -> String {
        var text = "Context \(usage.used) of \(usage.size) tokens"
        if let fraction = usage.fraction {
            text += " (\(Int((fraction * 100).rounded())) percent)"
        }
        if let cost = usage.cost {
            text += ", cost \(formatUsageCost(cost))"
        }
        return text
    }

    private func formatUsageCost(_ cost: ACPUsageCost) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = cost.currency
        formatter.maximumFractionDigits = cost.amount < 1 ? 4 : 2
        return formatter.string(from: NSNumber(value: cost.amount))
            ?? String(format: "%.2f %@", cost.amount, cost.currency)
    }

    @ViewBuilder
    func configOptionControl(for option: ACPSessionConfigOption) -> some View {
        let isModelOption = option.id == ACPModelConfig.configId
        let iconName: String = {
            if isModelOption { return "cpu" }
            if option.id == "thought_level" { return "brain" }
            return "slider.horizontal.3"
        }()
        let identifier = isModelOption ? "acp-model-picker" : "acp-config-\(option.id)"

        switch option.kind {
        case .select(let choices):
            Menu {
                ForEach(choices) { choice in
                    Button {
                        sessionViewModel.sendSetConfigOption(
                            configId: option.id,
                            value: .string(choice.id),
                            sessionId: serverViewModel.sessionId,
                            serverId: serverViewModel.id
                        )
                    } label: {
                        HStack {
                            Text(choice.name)
                            if option.currentValue.stringValue == choice.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: iconName)
                        .font(.caption.weight(.semibold))
                    Text(option.selectedChoiceName ?? option.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier(identifier)
        case .boolean:
            Button {
                let currentValue = option.currentValue.boolValue ?? false
                sessionViewModel.sendSetConfigOption(
                    configId: option.id,
                    value: .bool(!currentValue),
                    sessionId: serverViewModel.sessionId,
                    serverId: serverViewModel.id
                )
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: (option.currentValue.boolValue ?? false) ? "checkmark.circle.fill" : "circle")
                        .font(.caption.weight(.semibold))
                    Text(option.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background((option.currentValue.boolValue ?? false) ? Color.green.opacity(0.15) : Color(.systemGray5))
                .foregroundStyle((option.currentValue.boolValue ?? false) ? Color.green : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        case .unknown:
            EmptyView()
        }
    }

    func iconForMode(_ modeId: String?) -> String {
        guard let modeId = modeId?.lowercased() else { return "slider.horizontal.3" }

        switch modeId {
        case "plan", "architect":
            return "list.bullet.clipboard"
        case "code", "auto-edit":
            return "chevron.left.forwardslash.chevron.right"
        case "ask", "chat":
            return "bubble.left.and.bubble.right"
        case "yolo", "auto":
            return "bolt.fill"
        case "debug":
            return "ladybug"
        default:
            return "slider.horizontal.3"
        }
    }

    func colorForMode(_ modeId: String?) -> Color {
        guard let modeId = modeId?.lowercased() else { return .blue }

        switch modeId {
        case "plan", "architect":
            return .purple
        case "code", "auto-edit":
            return .orange
        case "ask", "chat":
            return .blue
        case "yolo", "auto":
            return .red
        case "debug":
            return .green
        default:
            return .blue
        }
    }

}
