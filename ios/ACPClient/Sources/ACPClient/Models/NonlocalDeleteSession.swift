import ACP
import Foundation

/// Reserved JSON-RPC integer error codes returned by `nonlocal/delete_session`.
/// Callers map directly from `ACPServiceError.rpcCode` without modifying `ACPError`.
public enum NonlocalDeleteErrorCode: Int, Codable, Equatable, Sendable {
    case sessionActive = -32021
    case dbBusy = -32022
    case deleteFailed = -32023
    case storageUnconfigured = -32024

    public init?(serviceError: ACPServiceError) {
        guard let code = serviceError.rpcCode else { return nil }
        self.init(rawValue: code)
    }
}

public struct NonlocalDeleteSessionResult: Codable, Equatable, Sendable {
    public let sessionId: String
    public let deleted: Bool
    public let alreadyAbsent: Bool
    public let deletedSubagentIds: [String]
    public let deletedSubagentCount: Int
    public let warnings: [String]

    public init(
        sessionId: String,
        deleted: Bool,
        alreadyAbsent: Bool = false,
        deletedSubagentIds: [String] = [],
        deletedSubagentCount: Int = 0,
        warnings: [String] = []
    ) {
        self.sessionId = sessionId
        self.deleted = deleted
        self.alreadyAbsent = alreadyAbsent
        self.deletedSubagentIds = deletedSubagentIds
        self.deletedSubagentCount = deletedSubagentCount
        self.warnings = warnings
    }

    public static func parse(from result: ACP.Value?) -> NonlocalDeleteSessionResult? {
        guard let object = result?.objectValue,
              let sessionId = nonEmptyString(object["sessionId"]) else {
            return nil
        }

        let deleted = object["deleted"]?.boolValue ?? false
        let alreadyAbsent = object["alreadyAbsent"]?.boolValue ?? false

        let deletedSubagentIds: [String]
        if case let .array(rawIds)? = object["deletedSubagentIds"] {
            deletedSubagentIds = rawIds.compactMap(nonEmptyString)
        } else {
            deletedSubagentIds = []
        }

        let deletedSubagentCount = parseInt(object["deletedSubagentCount"]) ?? deletedSubagentIds.count

        let warnings: [String]
        if case let .array(rawWarnings)? = object["warnings"] {
            warnings = rawWarnings.compactMap(nonEmptyString)
        } else {
            warnings = []
        }

        return NonlocalDeleteSessionResult(
            sessionId: sessionId,
            deleted: deleted,
            alreadyAbsent: alreadyAbsent,
            deletedSubagentIds: deletedSubagentIds,
            deletedSubagentCount: deletedSubagentCount,
            warnings: warnings
        )
    }

    private static func parseInt(_ value: ACP.Value?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let intVal):
            return intVal
        case .double(let doubleVal):
            return Int(exactly: doubleVal)
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: ACP.Value?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }
}
