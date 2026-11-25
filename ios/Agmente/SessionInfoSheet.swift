import SwiftUI
import ACPClient
import UIKit

struct SessionInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppViewModel
    let sessionId: String
    let localTitle: String?
    let localCwd: String?
    var serverId: UUID? = nil

    @State private var remoteInfo: NonlocalSessionInfoResult?
    @State private var isLoading = false
    @State private var remoteUnavailable = false
    @State private var copiedField: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Local Session Info") {
                    copyableRow(
                        label: "Session ID",
                        rawValue: sessionId,
                        fallbackPlaceholder: "—",
                        fieldKey: "sessionId",
                        monospaced: true,
                        copyable: !sessionId.isEmpty,
                        buttonId: "session-info-copy-id"
                    )
                    copyableRow(
                        label: "Display Title",
                        rawValue: rawDisplayTitle,
                        fallbackPlaceholder: "Untitled",
                        fieldKey: "displayTitle",
                        monospaced: false,
                        copyable: rawDisplayTitle != nil,
                        buttonId: "session-info-copy-title"
                    )
                    copyableRow(
                        label: "Working Directory",
                        rawValue: rawEffectiveCwd,
                        fallbackPlaceholder: "—",
                        fieldKey: "cwd",
                        monospaced: true,
                        copyable: rawEffectiveCwd != nil,
                        buttonId: "session-info-copy-cwd"
                    )
                }

                Section("Antigravity Remote Info") {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading original title and subagents…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if remoteUnavailable {
                        Label(
                            "Offline or server does not support remote session info",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("session-info-unavailable-notice")
                    } else {
                        copyableRow(
                            label: "Antigravity Original Title",
                            rawValue: rawUpstreamTitle,
                            fallbackPlaceholder: "None",
                            fieldKey: "upstreamTitle",
                            monospaced: false,
                            copyable: rawUpstreamTitle != nil,
                            buttonId: "session-info-copy-upstream-title"
                        )

                        if let subagents = remoteInfo?.subagents, !subagents.isEmpty {
                            ForEach(Array(subagents.enumerated()), id: \.element.sessionId) { index, sub in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let upstream = sub.upstreamTitle, !upstream.isEmpty {
                                            Text(upstream)
                                                .font(.subheadline.weight(.medium))
                                        } else {
                                            Text("Subagent \(index + 1)")
                                                .font(.subheadline.weight(.medium))
                                        }
                                        Text(sub.sessionId)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    Button {
                                        copyToClipboard(sub.sessionId, fieldKey: "sub-\(sub.sessionId)")
                                    } label: {
                                        Image(systemName: copiedField == "sub-\(sub.sessionId)" ? "checkmark" : "doc.on.doc")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("session-info-copy-subagent-\(index)")
                                }
                            }
                        } else {
                            Text("No linked subagents")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("session-info-no-subagents")
                        }
                    }
                }
            }
            .navigationTitle("Session Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("session-info-done-button")
                }
            }
            .task(id: sessionId) {
                await loadRemoteInfo()
            }
        }
    }

    private var rawDisplayTitle: String? {
        if let remote = remoteInfo?.displayTitle, !remote.isEmpty {
            return remote
        }
        if let localTitle, !localTitle.isEmpty {
            return localTitle
        }
        return nil
    }

    private var rawEffectiveCwd: String? {
        if let remote = remoteInfo?.cwd, !remote.isEmpty {
            return remote
        }
        if let localCwd, !localCwd.isEmpty {
            return localCwd
        }
        return nil
    }

    private var rawUpstreamTitle: String? {
        guard let title = remoteInfo?.upstreamTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    private func copyableRow(
        label: LocalizedStringKey,
        rawValue: String?,
        fallbackPlaceholder: LocalizedStringKey,
        fieldKey: String,
        monospaced: Bool,
        copyable: Bool,
        buttonId: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let rawValue, !rawValue.isEmpty {
                    Text(rawValue)
                        .font(monospaced ? .footnote.monospaced() : .subheadline)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                } else {
                    Text(fallbackPlaceholder)
                        .font(monospaced ? .footnote.monospaced() : .subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if copyable, let rawValue, !rawValue.isEmpty {
                Button {
                    copyToClipboard(rawValue, fieldKey: fieldKey)
                } label: {
                    Image(systemName: copiedField == fieldKey ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(buttonId)
            }
        }
    }

    private func copyToClipboard(_ text: String, fieldKey: String) {
        UIPasteboard.general.string = text
        copiedField = fieldKey
    }

    private func loadRemoteInfo() async {
        let isConnected: Bool = {
            if let serverId {
                return model.connectionState(for: serverId) == .connected
            }
            return model.connectionState == .connected
        }()
        guard isConnected else {
            remoteUnavailable = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        let fetched: NonlocalSessionInfoResult?
        if let targetId = serverId ?? model.selectedServer?.id {
            fetched = try? await model.fetchSessionInfo(serverId: targetId, sessionId: sessionId)
        } else {
            fetched = nil
        }
        if let fetched {
            remoteInfo = fetched
            remoteUnavailable = false
        } else {
            remoteUnavailable = true
        }
    }
}
