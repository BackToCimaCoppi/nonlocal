import Foundation
import ACPClient

struct ACPServerConfiguration: Identifiable, Equatable {
    let id: UUID
    var name: String
    var scheme: String
    var host: String
    var token: String
    var workingDirectory: String

    var endpointURLString: String {
        "\(scheme)://\(host)"
    }

    init(
        id: UUID,
        name: String,
        scheme: String,
        host: String,
        token: String,
        workingDirectory: String
    ) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.host = host
        self.token = token
        self.workingDirectory = workingDirectory
    }
}

struct ValidatedServerConfiguration {
    let name: String
    let scheme: String
    let host: String
    let token: String
    let workingDirectory: String
    let agentInfo: AgentProfile?
}

struct LogLine: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let message: String

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var timestampLabel: String {
        Self.timestampFormatter.string(from: timestamp)
    }

    var title: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: ": ") {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    var details: String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: ": ") else { return nil }
        let remainder = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
    }

    /// Attempts to pretty-print JSON details for easier reading.
    var prettyDetails: String? {
        guard
            let details = details,
            let data = details.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(jsonObject),
            let pretty = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted]),
            let string = String(data: pretty, encoding: .utf8)
        else { return nil }
        return string
    }

    var formattedLine: String {
        "[\(timestampLabel)] \(message)"
    }
}
