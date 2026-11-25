import ACP
import Foundation

public struct NonlocalUsageTier: Codable, Equatable, Sendable {
    public let name: String?
    public let id: String?

    public init(name: String? = nil, id: String? = nil) {
        self.name = name
        self.id = id
    }
}

public struct NonlocalUsageBucket: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let window: String
    public let remainingFraction: Double
    public let resetTime: String?

    public init(
        id: String,
        name: String,
        window: String,
        remainingFraction: Double,
        resetTime: String? = nil
    ) {
        self.id = id
        self.name = name
        self.window = window
        self.remainingFraction = remainingFraction
        self.resetTime = resetTime
    }
}

public struct NonlocalUsageGroup: Codable, Equatable, Sendable {
    public let name: String
    public let description: String?
    public let buckets: [NonlocalUsageBucket]

    public init(
        name: String,
        description: String? = nil,
        buckets: [NonlocalUsageBucket] = []
    ) {
        self.name = name
        self.description = description
        self.buckets = buckets
    }
}

public struct NonlocalUsageError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let failedAt: String?

    public init(code: String, message: String, failedAt: String? = nil) {
        self.code = code
        self.message = message
        self.failedAt = failedAt
    }
}

public struct NonlocalUsageResult: Codable, Equatable, Sendable {
    public let fetchedAt: String?
    public let ageSeconds: Int?
    public let ttlSeconds: Int
    public let refreshing: Bool
    public let tier: NonlocalUsageTier?
    public let groups: [NonlocalUsageGroup]
    public let lastError: NonlocalUsageError?

    public init(
        fetchedAt: String? = nil,
        ageSeconds: Int? = nil,
        ttlSeconds: Int = 180,
        refreshing: Bool = false,
        tier: NonlocalUsageTier? = nil,
        groups: [NonlocalUsageGroup] = [],
        lastError: NonlocalUsageError? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.ageSeconds = ageSeconds
        self.ttlSeconds = ttlSeconds
        self.refreshing = refreshing
        self.tier = tier
        self.groups = groups
        self.lastError = lastError
    }
}

public enum NonlocalUsageParser {
    public static func parse(from value: ACP.Value?) -> NonlocalUsageResult? {
        guard let object = value?.objectValue else {
            return nil
        }

        let fetchedAt = nonEmptyString(object["fetchedAt"])
        let ageSeconds = parseInt(object["ageSeconds"])
        let ttlSeconds = parseInt(object["ttlSeconds"]) ?? 180
        let refreshing = object["refreshing"]?.boolValue ?? false
        let tier = parseTier(from: object["tier"])

        let groups: [NonlocalUsageGroup]
        if case let .array(rawGroups)? = object["groups"] {
            groups = rawGroups.compactMap(parseGroup(from:))
        } else {
            groups = []
        }

        let lastError = parseError(from: object["lastError"])

        return NonlocalUsageResult(
            fetchedAt: fetchedAt,
            ageSeconds: ageSeconds,
            ttlSeconds: ttlSeconds,
            refreshing: refreshing,
            tier: tier,
            groups: groups,
            lastError: lastError
        )
    }

    private static func parseTier(from value: ACP.Value?) -> NonlocalUsageTier? {
        guard let object = value?.objectValue else { return nil }
        let name = nonEmptyString(object["name"])
        let id = nonEmptyString(object["id"])
        guard name != nil || id != nil else { return nil }
        return NonlocalUsageTier(name: name, id: id)
    }

    private static func parseGroup(from value: ACP.Value) -> NonlocalUsageGroup? {
        guard let object = value.objectValue,
              let name = nonEmptyString(object["name"]) else {
            return nil
        }
        let description = nonEmptyString(object["description"])
        let buckets: [NonlocalUsageBucket]
        if case let .array(rawBuckets)? = object["buckets"] {
            buckets = rawBuckets.compactMap(parseBucket(from:))
        } else {
            buckets = []
        }
        return NonlocalUsageGroup(name: name, description: description, buckets: buckets)
    }

    private static func parseBucket(from value: ACP.Value) -> NonlocalUsageBucket? {
        guard let object = value.objectValue,
              let id = nonEmptyString(object["id"]),
              let name = nonEmptyString(object["name"]),
              let window = nonEmptyString(object["window"]),
              let remainingFraction = object["remainingFraction"]?.numberValue else {
            return nil
        }
        let resetTime = nonEmptyString(object["resetTime"])
        return NonlocalUsageBucket(
            id: id,
            name: name,
            window: window,
            remainingFraction: remainingFraction,
            resetTime: resetTime
        )
    }

    private static func parseError(from value: ACP.Value?) -> NonlocalUsageError? {
        guard let object = value?.objectValue,
              let code = nonEmptyString(object["code"]),
              let message = nonEmptyString(object["message"]) else {
            return nil
        }
        let failedAt = nonEmptyString(object["failedAt"])
        return NonlocalUsageError(code: code, message: message, failedAt: failedAt)
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
