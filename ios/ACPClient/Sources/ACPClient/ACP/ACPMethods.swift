import Foundation

enum ACPMethods {
    static let initialize = "initialize"
    static let sessionNew = "session/new"
    static let sessionLoad = "session/load"
    static let sessionPrompt = "session/prompt"
    static let sessionCancel = "session/cancel"
    static let sessionList = "session/list"
    static let sessionSetMode = "session/set_mode"
    static let sessionSetConfigOption = "session/set_config_option"
}

/// Standard ACP model config option identifier used with `session/set_config_option`.
public enum ACPModelConfig {
    public static let configId = "model"
}
