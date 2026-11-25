import ACP
import Foundation

/// Reserved JSON-RPC integer error codes returned by `nonlocal/fs_list` and
/// `nonlocal/fs_read_file`. Callers compare directly against `ACPServiceError.rpcCode`.
public enum NonlocalFsErrorCode: Int, Codable, Equatable, Sendable {
    case notFound = -32011
    case notDirectory = -32012
    case permissionDenied = -32013
    case isDirectory = -32014
    case unsupportedBinary = -32015
    case fileTooLarge = -32016
    case invalidParams = -32602
}

public enum NonlocalFsEntryType: String, Codable, Equatable, Sendable {
    case dir
    case file
    case symlink
}

public enum NonlocalFsTargetType: String, Codable, Equatable, Sendable {
    case dir
    case file
    case broken
}

public struct NonlocalFsEntry: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let type: NonlocalFsEntryType
    public let targetType: NonlocalFsTargetType?
    public let size: Int64?
    public let mtimeMs: Int64?

    public init(
        name: String,
        path: String,
        type: NonlocalFsEntryType,
        targetType: NonlocalFsTargetType? = nil,
        size: Int64? = nil,
        mtimeMs: Int64? = nil
    ) {
        self.name = name
        self.path = path
        self.type = type
        self.targetType = targetType
        self.size = size
        self.mtimeMs = mtimeMs
    }
}

public struct NonlocalFsListParams: Codable, Equatable, Sendable {
    public var path: String?
    public var includeFiles: Bool?
    public var showHidden: Bool?
    public var query: String?
    public var limit: Int?

    public init(
        path: String? = nil,
        includeFiles: Bool? = nil,
        showHidden: Bool? = nil,
        query: String? = nil,
        limit: Int? = nil
    ) {
        self.path = path
        self.includeFiles = includeFiles
        self.showHidden = showHidden
        self.query = query
        self.limit = limit
    }

    public func acpValue() -> ACP.Value {
        var object: [String: ACP.Value] = [:]
        if let path {
            object["path"] = .string(path)
        }
        if let includeFiles {
            object["includeFiles"] = .bool(includeFiles)
        }
        if let showHidden {
            object["showHidden"] = .bool(showHidden)
        }
        if let query {
            object["query"] = .string(query)
        }
        if let limit {
            object["limit"] = .int(limit)
        }
        return .object(object)
    }
}

public struct NonlocalFsListResult: Codable, Equatable, Sendable {
    public let path: String
    public let parentPath: String?
    public let homePath: String
    public let totalCount: Int
    public let truncated: Bool
    public let entries: [NonlocalFsEntry]

    public init(
        path: String,
        parentPath: String? = nil,
        homePath: String,
        totalCount: Int,
        truncated: Bool = false,
        entries: [NonlocalFsEntry] = []
    ) {
        self.path = path
        self.parentPath = parentPath
        self.homePath = homePath
        self.totalCount = totalCount
        self.truncated = truncated
        self.entries = entries
    }
}

public enum NonlocalFsFileKind: String, Codable, Equatable, Sendable {
    case text
    case image
}

public struct NonlocalFsReadFileResult: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let kind: NonlocalFsFileKind
    public let mimeType: String
    public let content: String
    public let size: Int64
    public let bytesRead: Int64
    public let truncated: Bool
    public let mtimeMs: Int64?

    public init(
        path: String,
        name: String,
        kind: NonlocalFsFileKind,
        mimeType: String,
        content: String,
        size: Int64,
        bytesRead: Int64,
        truncated: Bool = false,
        mtimeMs: Int64? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.mimeType = mimeType
        self.content = content
        self.size = size
        self.bytesRead = bytesRead
        self.truncated = truncated
        self.mtimeMs = mtimeMs
    }
}

public enum NonlocalFileSystemParser {
    public static func parseFsList(from value: ACP.Value?) -> NonlocalFsListResult? {
        guard let object = value?.objectValue,
              let path = nonEmptyString(object["path"]),
              let homePath = nonEmptyString(object["homePath"]) else {
            return nil
        }

        let parentPath = nonEmptyString(object["parentPath"])
        let entries: [NonlocalFsEntry]
        if case let .array(rawEntries)? = object["entries"] {
            entries = rawEntries.compactMap(parseEntry(from:))
        } else {
            entries = []
        }

        let totalCount = parseInt(object["totalCount"]) ?? entries.count
        let truncated = object["truncated"]?.boolValue ?? false

        return NonlocalFsListResult(
            path: path,
            parentPath: parentPath,
            homePath: homePath,
            totalCount: totalCount,
            truncated: truncated,
            entries: entries
        )
    }

    public static func parseFsReadFile(from value: ACP.Value?) -> NonlocalFsReadFileResult? {
        guard let object = value?.objectValue,
              let path = nonEmptyString(object["path"]),
              let name = nonEmptyString(object["name"]),
              let kindRaw = object["kind"]?.stringValue,
              let kind = NonlocalFsFileKind(rawValue: kindRaw),
              let mimeType = nonEmptyString(object["mimeType"]),
              let content = object["content"]?.stringValue,
              let size = parseInt64(object["size"]),
              let bytesRead = parseInt64(object["bytesRead"]) else {
            return nil
        }

        let truncated = object["truncated"]?.boolValue ?? false
        let mtimeMs = parseInt64(object["mtimeMs"])

        return NonlocalFsReadFileResult(
            path: path,
            name: name,
            kind: kind,
            mimeType: mimeType,
            content: content,
            size: size,
            bytesRead: bytesRead,
            truncated: truncated,
            mtimeMs: mtimeMs
        )
    }

    private static func parseEntry(from value: ACP.Value) -> NonlocalFsEntry? {
        guard let object = value.objectValue,
              let name = nonEmptyString(object["name"]),
              let path = nonEmptyString(object["path"]),
              let typeRaw = object["type"]?.stringValue,
              let type = NonlocalFsEntryType(rawValue: typeRaw) else {
            return nil
        }

        let targetType = object["targetType"]?.stringValue.flatMap(NonlocalFsTargetType.init(rawValue:))
        let size = parseInt64(object["size"])
        let mtimeMs = parseInt64(object["mtimeMs"])

        return NonlocalFsEntry(
            name: name,
            path: path,
            type: type,
            targetType: targetType,
            size: size,
            mtimeMs: mtimeMs
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

    private static func parseInt64(_ value: ACP.Value?) -> Int64? {
        guard let value else { return nil }
        switch value {
        case .int(let intVal):
            return Int64(intVal)
        case .double(let doubleVal):
            guard doubleVal.isFinite else { return nil }
            return Int64(doubleVal.rounded())
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: ACP.Value?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }
}
