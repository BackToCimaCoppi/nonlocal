import Foundation
import SwiftUI
import ACP
import ACPClient

struct DefaultThoughtLevelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct DefaultModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let thoughtLevels: [DefaultThoughtLevelOption]
}

struct DefaultModelSelection: Equatable, Sendable {
    let modelId: String
    let thoughtLevel: String?
}

/// Per-server default model & thinking level preferences stored in `UserDefaults`.
struct DefaultModelPreferences {
    static let factoryDefaultModelId = "gemini-4-neon"
    static let factoryDefaultThoughtLevel = "medium"

    static let standardThreeLevels: [DefaultThoughtLevelOption] = [
        DefaultThoughtLevelOption(id: "low", name: "Low"),
        DefaultThoughtLevelOption(id: "medium", name: "Medium"),
        DefaultThoughtLevelOption(id: "high", name: "High"),
    ]

    static let fourLevelsWithXHigh: [DefaultThoughtLevelOption] = [
        DefaultThoughtLevelOption(id: "low", name: "Low"),
        DefaultThoughtLevelOption(id: "medium", name: "Medium"),
        DefaultThoughtLevelOption(id: "high", name: "High"),
        DefaultThoughtLevelOption(id: "xhigh", name: "XHigh"),
    ]

    /// Fallback catalog used before a server has reported its live `configOptions`.
    static let builtInModels: [DefaultModelOption] = [
        DefaultModelOption(id: "gemini-4-neon", name: "Gemini 4 Neon", thoughtLevels: fourLevelsWithXHigh),
        DefaultModelOption(id: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen", thoughtLevels: fourLevelsWithXHigh),
        DefaultModelOption(id: "gemini-4-carbon", name: "Gemini 4 Carbon", thoughtLevels: standardThreeLevels),
        DefaultModelOption(id: "gemini-4-argon", name: "Gemini 4 Argon", thoughtLevels: standardThreeLevels),
        DefaultModelOption(id: "gemini-pro-orchestrator-neon", name: "Orchestrator (Neon)", thoughtLevels: []),
        DefaultModelOption(id: "gemini-pro-orchestrator", name: "Orchestrator (Carbon)", thoughtLevels: []),
        DefaultModelOption(id: "gemini-pro-orchestrator-argon", name: "Orchestrator (Argon)", thoughtLevels: []),
        DefaultModelOption(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", thoughtLevels: standardThreeLevels),
        DefaultModelOption(id: "claude-opus-5-5", name: "Claude Opus 5.5", thoughtLevels: standardThreeLevels),
        DefaultModelOption(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", thoughtLevels: standardThreeLevels),
        DefaultModelOption(id: "gpt-oss-120b-medium", name: "GPT-OSS 120B (Medium)", thoughtLevels: []),
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func modelKey(for serverId: UUID) -> String {
        "nonlocal.defaultModel.\(serverId.uuidString)"
    }

    private func thoughtLevelKey(for serverId: UUID) -> String {
        "nonlocal.defaultThoughtLevel.\(serverId.uuidString)"
    }

    func selection(for serverId: UUID) -> DefaultModelSelection {
        let storedModel = defaults.string(forKey: modelKey(for: serverId))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId = (storedModel?.isEmpty == false) ? storedModel! : Self.factoryDefaultModelId

        let hasStoredThought = defaults.object(forKey: thoughtLevelKey(for: serverId)) != nil
        let rawThought = defaults.string(forKey: thoughtLevelKey(for: serverId))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let thoughtLevel: String?
        if hasStoredThought {
            thoughtLevel = (rawThought?.isEmpty == false) ? rawThought : nil
        } else if storedModel == nil {
            thoughtLevel = Self.factoryDefaultThoughtLevel
        } else {
            thoughtLevel = Self.defaultThoughtLevel(forModelId: modelId)
        }

        return DefaultModelSelection(modelId: modelId, thoughtLevel: thoughtLevel)
    }

    func save(modelId: String, thoughtLevel: String?, for serverId: UUID) {
        let trimmedModel = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        defaults.set(trimmedModel, forKey: modelKey(for: serverId))
        let trimmedThought = thoughtLevel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        defaults.set(trimmedThought, forKey: thoughtLevelKey(for: serverId))
    }

    static func defaultThoughtLevel(forModelId modelId: String, availableModels: [DefaultModelOption] = builtInModels) -> String? {
        guard let option = availableModels.first(where: { $0.id == modelId }), !option.thoughtLevels.isEmpty else {
            return nil
        }
        if option.thoughtLevels.contains(where: { $0.id == factoryDefaultThoughtLevel }) {
            return factoryDefaultThoughtLevel
        }
        return option.thoughtLevels.first?.id
    }

    /// Builds the model catalog for a single server:
    /// prefers that server's cached `configOptions` when available, otherwise falls back to `builtInModels`.
    /// Never borrows `thought_level.options` from a different active model.
    static func catalog(fromServerConfigOptions serverConfigOptions: [ACPSessionConfigOption]?) -> [DefaultModelOption] {
        guard let serverConfigOptions,
              let modelConfig = serverConfigOptions.first(where: { $0.id == ACPModelConfig.configId }),
              case .select(let choices) = modelConfig.kind,
              !choices.isEmpty else {
            return builtInModels
        }

        let activeModelId = modelConfig.currentValue.stringValue
        let activeThoughtOptions: [DefaultThoughtLevelOption]? = {
            guard let thoughtConfig = serverConfigOptions.first(where: { $0.id == "thought_level" }),
                  case .select(let thoughtChoices) = thoughtConfig.kind,
                  !thoughtChoices.isEmpty else {
                return nil
            }
            return thoughtChoices.map { DefaultThoughtLevelOption(id: $0.id, name: $0.name) }
        }()

        let builtInById = Dictionary(uniqueKeysWithValues: builtInModels.map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [DefaultModelOption] = []
        for choice in choices {
            guard seen.insert(choice.id).inserted else { continue }
            let levels: [DefaultThoughtLevelOption]
            if choice.id == activeModelId, let activeThoughtOptions {
                levels = activeThoughtOptions
            } else if let known = builtInById[choice.id] {
                levels = known.thoughtLevels
            } else {
                // Unknown dynamically discovered model: do not guess or borrow another model's thought levels.
                levels = []
            }
            result.append(DefaultModelOption(id: choice.id, name: choice.name, thoughtLevels: levels))
        }
        return result.isEmpty ? builtInModels : result
    }

    /// Resolves a valid thinking level for `modelId` within `catalog`.
    static func resolvedThoughtLevel(
        preferred: String?,
        forModelId modelId: String,
        in catalog: [DefaultModelOption]
    ) -> String? {
        guard let option = catalog.first(where: { $0.id == modelId }), !option.thoughtLevels.isEmpty else {
            return nil
        }
        if let preferred, option.thoughtLevels.contains(where: { $0.id == preferred }) {
            return preferred
        }
        if option.thoughtLevels.contains(where: { $0.id == factoryDefaultThoughtLevel }) {
            return factoryDefaultThoughtLevel
        }
        return option.thoughtLevels.first?.id
    }

    func normalizedSelection(
        for serverId: UUID,
        serverConfigOptions: [ACPSessionConfigOption]? = nil
    ) -> DefaultModelSelection {
        let raw = selection(for: serverId)
        let models = Self.catalog(fromServerConfigOptions: serverConfigOptions)
        let normalizedThought = Self.resolvedThoughtLevel(
            preferred: raw.thoughtLevel,
            forModelId: raw.modelId,
            in: models
        )
        return DefaultModelSelection(modelId: raw.modelId, thoughtLevel: normalizedThought)
    }

    func sessionCreateMeta(
        for serverId: UUID,
        serverConfigOptions: [ACPSessionConfigOption]? = nil
    ) -> [String: ACP.Value] {
        let effective = normalizedSelection(for: serverId, serverConfigOptions: serverConfigOptions)
        var meta: [String: ACP.Value] = [
            NonlocalMethods.defaultModelMetaKey: .string(effective.modelId),
        ]
        if let thought = effective.thoughtLevel, !thought.isEmpty {
            meta[NonlocalMethods.defaultThoughtLevelMetaKey] = .string(thought)
        }
        return meta
    }
}

/// Compact per-server default model & thinking level picker sheet opened from the ACP server card gear button.
struct ServerDefaultModelSheet: View {
    @Environment(\.dismiss) private var dismiss

    let serverId: UUID
    let serverName: String
    let serverConfigOptions: [ACPSessionConfigOption]?
    let preferences: DefaultModelPreferences

    @State private var selectedModelId: String
    @State private var selectedThoughtLevel: String

    private var catalog: [DefaultModelOption] {
        DefaultModelPreferences.catalog(fromServerConfigOptions: serverConfigOptions)
    }

    private var selectedModelOption: DefaultModelOption? {
        catalog.first(where: { $0.id == selectedModelId })
    }

    private var availableThoughtLevels: [DefaultThoughtLevelOption] {
        selectedModelOption?.thoughtLevels ?? []
    }

    init(
        serverId: UUID,
        serverName: String,
        serverConfigOptions: [ACPSessionConfigOption]?,
        preferences: DefaultModelPreferences
    ) {
        self.serverId = serverId
        self.serverName = serverName
        self.serverConfigOptions = serverConfigOptions
        self.preferences = preferences
        let initial = preferences.normalizedSelection(for: serverId, serverConfigOptions: serverConfigOptions)
        _selectedModelId = State(initialValue: initial.modelId)
        _selectedThoughtLevel = State(initialValue: initial.thoughtLevel ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default Model", selection: $selectedModelId) {
                        ForEach(catalog) { option in
                            Text(option.name).tag(option.id)
                        }
                        if !catalog.contains(where: { $0.id == selectedModelId }) {
                            Text(selectedModelId).tag(selectedModelId)
                        }
                    }
                    .accessibilityIdentifier("ServerDefaultModelPicker")
                    .onChange(of: selectedModelId) { _, newModelId in
                        let resolved = DefaultModelPreferences.resolvedThoughtLevel(
                            preferred: selectedThoughtLevel.isEmpty ? nil : selectedThoughtLevel,
                            forModelId: newModelId,
                            in: catalog
                        )
                        selectedThoughtLevel = resolved ?? ""
                        preferences.save(modelId: newModelId, thoughtLevel: resolved, for: serverId)
                    }

                    if !availableThoughtLevels.isEmpty {
                        Picker("Reasoning Effort", selection: $selectedThoughtLevel) {
                            ForEach(availableThoughtLevels) { level in
                                Text(level.name).tag(level.id)
                            }
                        }
                        .accessibilityIdentifier("ServerDefaultThoughtLevelPicker")
                        .onChange(of: selectedThoughtLevel) { _, newLevel in
                            let value = newLevel.isEmpty ? nil : newLevel
                            preferences.save(modelId: selectedModelId, thoughtLevel: value, for: serverId)
                        }
                    }
                } header: {
                    Text(serverName)
                } footer: {
                    Text("Applies only to new sessions on this server; manually switching the model in an existing session keeps your chosen model.")
                }
            }
            .navigationTitle("Default Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
