import SwiftUI
import ACPClient

/// Pure helper governing AddServerView default working directory & edit-mode browse gating (AC-302 / AC-303 / SD-2.8).
enum AddServerDirectoryGating {
    static func initialWorkingDirectory(editingServer: ACPServerConfiguration?) -> String {
        if let editingServer {
            return editingServer.workingDirectory
        }
        return "~"
    }

    static func canShowBrowseButton(
        editingServer: ACPServerConfiguration?,
        connectionState: ACPConnectionState,
        scheme: String,
        host: String,
        token: String
    ) -> Bool {
        guard let editingServer else { return false }
        guard connectionState == .connected else {
            return false
        }
        return AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: editingServer,
            scheme: scheme,
            host: host,
            token: token
        )
    }
}

/// Pure testable validation helpers for AddServerView (SH-3 / SC-AC-030 / SC-AC-031).
enum AddServerFormValidation {
    static func trimmedToken(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func canSave(name: String, host: String, token: String, isSaving: Bool) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !trimmedToken(token).isEmpty
            && !isSaving
    }

    static func shouldShowRootWorkingDirectoryWarning(_ workingDirectory: String) -> Bool {
        workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) == "/"
    }

    static func shouldPresentErrorAlert(for error: Error) -> Bool {
        if let validationError = error as? AddServerValidationError,
           validationError.isLocalNetworkPermissionError {
            return false
        }
        return true
    }
}

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var name: String = ""
    @State private var scheme: String = "ws"
    @State private var host: String = ""
    @State private var token: String = ""
    @State private var workingDirectory: String = ""
    @State private var hasUserEditedWorkingDirectory: Bool = false
    @State private var isProgrammaticallyUpdatingWorkingDirectory: Bool = false
    @State private var showingDirectoryPicker: Bool = false
    @State private var isSaving = false
    @State private var isNormalizingHost = false
    @State private var errorMessage: String?
    @State private var showError = false

    let editingServer: ACPServerConfiguration?
    let connectionState: ACPConnectionState
    let recentWorkingDirectories: [String]
    let listDirectory: ((NonlocalFsListParams) async throws -> NonlocalFsListResult?)?
    let onValidate: (String, String, String, String, String) async -> Result<ValidatedServerConfiguration, Error>
    let onInsert: (ValidatedServerConfiguration) -> Void

    init(
        editingServer: ACPServerConfiguration? = nil,
        connectionState: ACPConnectionState = .disconnected,
        recentWorkingDirectories: [String] = [],
        listDirectory: ((NonlocalFsListParams) async throws -> NonlocalFsListResult?)? = nil,
        onValidate: @escaping (String, String, String, String, String) async -> Result<ValidatedServerConfiguration, Error>,
        onInsert: @escaping (ValidatedServerConfiguration) -> Void
    ) {
        self.editingServer = editingServer
        self.connectionState = connectionState
        self.recentWorkingDirectories = recentWorkingDirectories
        self.listDirectory = listDirectory
        self.onValidate = onValidate
        self.onInsert = onInsert

        _name = State(initialValue: editingServer?.name ?? "")
        _scheme = State(initialValue: editingServer?.scheme ?? "ws")
        _host = State(initialValue: editingServer?.host ?? "")
        _token = State(initialValue: editingServer?.token ?? "")
        let initialDir = AddServerDirectoryGating.initialWorkingDirectory(editingServer: editingServer)
        _workingDirectory = State(initialValue: initialDir)
    }

    private enum Field: Hashable {
        case name
        case host
        case token
        case workingDirectory
    }

    @ViewBuilder
    private var formSections: some View {
        Section {
            TextField("Display name", text: $name)
                .focused($focusedField, equals: .name)
                .accessibilityIdentifier("ServerNameField")
        }

        Section {
            Picker("Protocol", selection: $scheme) {
                Text("ws").tag("ws")
                Text("wss").tag("wss")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ProtocolPicker")

            TextField("Host", text: $host)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .onChange(of: host, perform: normalizeHostInput)
                .focused($focusedField, equals: .host)
                .accessibilityIdentifier("HostField")

            SecureField("Bearer token", text: $token)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focusedField, equals: .token)
                .accessibilityIdentifier("TokenField")
        }

        Section {
            HStack(spacing: 8) {
                TextField("Working directory", text: $workingDirectory)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .workingDirectory)
                    .accessibilityIdentifier("WorkingDirectoryField")
                    .onChange(of: workingDirectory) { _, _ in
                        if !isProgrammaticallyUpdatingWorkingDirectory {
                            hasUserEditedWorkingDirectory = true
                        }
                    }

                if canBrowseRemoteDirectory {
                    Button("Browse") {
                        showingDirectoryPicker = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("AddServerBrowseDirectoryButton")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Default working directory used when creating new sessions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if AddServerFormValidation.shouldShowRootWorkingDirectoryWarning(workingDirectory) {
                    Label("Using root (/) as working directory is dangerous and may crash the agent.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                        .accessibilityIdentifier("rootWorkingDirectoryWarning")
                }
            }
        }

        Section {
            Button {
                saveServer()
            } label: {
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .padding(.trailing, 8)
                    }
                    Text(editingServer == nil ? "Save Server" : "Update Server")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!canSave)
            .accessibilityIdentifier("SaveServerButton")
            .accessibilityLabel(editingServer == nil ? "Save Server" : "Update Server")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                formSections
            }
            .navigationTitle(editingServer == nil ? "Add Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveServer()
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                            Text(editingServer == nil ? "Save" : "Update")
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("saveToolbarButton")
                }
            }
        }
        .alert(editingServer == nil ? "Unable to Add Server" : "Unable to Update Server", isPresented: $showError) {
            Button("OK", role: .cancel) {
                showError = false
            }
        } message: {
            Text(errorMessage ?? String(localized: "Failed to connect to the server. Check the endpoint and credentials, then try again."))
        }
        .sheet(isPresented: $showingDirectoryPicker) {
            if let listDirectory {
                RemoteDirectoryPickerSheet(
                    initialPath: workingDirectory,
                    serverDefaultPath: editingServer?.workingDirectory ?? "~",
                    recentDirectories: recentWorkingDirectories,
                    listDirectory: listDirectory,
                    onSelect: { selectedPath in
                        isProgrammaticallyUpdatingWorkingDirectory = true
                        workingDirectory = selectedPath
                        isProgrammaticallyUpdatingWorkingDirectory = false
                        hasUserEditedWorkingDirectory = true
                    }
                )
            }
        }
    }

    private var canBrowseRemoteDirectory: Bool {
        guard listDirectory != nil else { return false }
        return AddServerDirectoryGating.canShowBrowseButton(
            editingServer: editingServer,
            connectionState: connectionState,
            scheme: scheme,
            host: host,
            token: token
        )
    }
}

private extension AddServerView {
    var canSave: Bool {
        AddServerFormValidation.canSave(name: name, host: host, token: token, isSaving: isSaving)
    }

    func saveServer() {
        guard canSave else { return }
        focusedField = nil
        performSave()
    }

    func performSave() {
        let normalized = Self.normalizeEndpointInputValue(host: host, scheme: scheme)
        let trimmedToken = AddServerFormValidation.trimmedToken(token)
        if Self.shouldSkipRemoteValidationOnEdit(
            editingServer: editingServer,
            scheme: normalized.scheme,
            host: normalized.host,
            token: trimmedToken
        ) {
            let validated = ValidatedServerConfiguration(
                name: name,
                scheme: normalized.scheme,
                host: normalized.host,
                token: trimmedToken,
                workingDirectory: workingDirectory,
                agentInfo: nil
            )
            onInsert(validated)
            dismiss()
            return
        }

        isSaving = true
        Task {
            let result = await onValidate(
                name,
                normalized.scheme,
                normalized.host,
                trimmedToken,
                workingDirectory
            )
            await MainActor.run {
                isSaving = false
                switch result {
                case .success(let validation):
                    onInsert(validation)
                    dismiss()
                case .failure(let error):
                    guard AddServerFormValidation.shouldPresentErrorAlert(for: error) else {
                        return
                    }
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    func normalizeHostInput(_ value: String) {
        guard !isNormalizingHost else { return }
        // Only normalize live when the user pastes a full scheme URL (ws:// or wss://),
        // so typing "host:port" character by character never loses the colon before the port.
        guard value.contains("://") else { return }
        let normalized = Self.normalizeEndpointInputValue(host: value, scheme: scheme)
        guard normalized.host != value || normalized.scheme != scheme else { return }

        isNormalizingHost = true
        host = normalized.host
        scheme = normalized.scheme
        isNormalizingHost = false
    }
}

extension AddServerView {
    /// Returns `true` when editing an existing server without changing any connection parameter
    /// (only display name or default working directory changed). Skipping out-of-pool validation
    /// avoids self-preempting the active WebSocket with close code 4001 and preserves lockout state (DEC-30).
    static func shouldSkipRemoteValidationOnEdit(
        editingServer: ACPServerConfiguration?,
        scheme: String,
        host: String,
        token: String
    ) -> Bool {
        guard let editingServer else { return false }
        let normalized = normalizeEndpointInputValue(host: host, scheme: scheme)
        let original = normalizeEndpointInputValue(host: editingServer.host, scheme: editingServer.scheme)
        return original.scheme == normalized.scheme
            && original.host == normalized.host
            && AddServerFormValidation.trimmedToken(editingServer.token) == AddServerFormValidation.trimmedToken(token)
    }

    static func normalizeEndpointInputValue(host: String, scheme: String) -> (scheme: String, host: String) {
        BridgeServerValidator.normalizeEndpoint(scheme: scheme, host: host)
    }
}
