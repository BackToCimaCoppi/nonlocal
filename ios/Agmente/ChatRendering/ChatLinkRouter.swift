import Foundation

enum ChatLinkAction: Equatable {
    case ignored
    case externalURL(URL)
    case remotePath(resolvedPath: String, prefersDirectory: Bool, startLine: Int?, endLine: Int?)

    var localizedLineAnchorHint: String? {
        guard case .remotePath(_, _, let startLine, let endLine) = self, let startLine else {
            return nil
        }
        if let endLine, endLine != startLine {
            return String(localized: "Lines \(startLine)–\(endLine)")
        }
        return String(localized: "Line \(startLine)")
    }
}

/// Pure-Foundation 6-step chat link router (T6 / DP-5.2 / AC-503 & AC-504).
enum ChatLinkRouter {
    private static let blockedSchemePrefixes = ["javascript:", "tel:", "data:", "about:", "sms:"]

    static func resolve(
        rawLink: String,
        sessionCwd: String,
        serverDefaultCwd: String
    ) -> ChatLinkAction {
        // Step 1: Trim whitespace and angle brackets; ignore empty or pure fragment "#..."
        var input = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("<") && input.hasSuffix(">") && input.count >= 2 {
            input = String(input.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !input.isEmpty, !input.hasPrefix("#") else {
            return .ignored
        }

        // Step 2: Allow http://, https://, mailto: as external URLs (preserving fragments)
        let lower = input.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            if let url = URL(string: input) {
                return .externalURL(url)
            }
            return .ignored
        }

        // Step 3: Strip trailing #... fragment (extracting #L... line hints, silently stripping #heading)
        // and trailing :line / :line:col BEFORE unknown-scheme rejection so `App.swift:42` is never misclassified.
        var pathPart = input
        var startLine: Int?
        var endLine: Int?

        if let hashIdx = pathPart.firstIndex(of: "#") {
            let fragment = String(pathPart[pathPart.index(after: hashIdx)...])
            pathPart = String(pathPart[..<hashIdx])
            guard !pathPart.isEmpty else { return .ignored }
            if let range = parseLineFragment(fragment) {
                startLine = range.startLine
                endLine = range.endLine
            }
        }

        if startLine == nil {
            if let match = matchTrailingColonLine(in: pathPart) {
                pathPart = match.prefix
                startLine = match.line
                endLine = nil
            }
        }

        guard !pathPart.isEmpty else { return .ignored }

        // Step 4: Block explicit non-whitelisted schemes (non-file:// xxx:// and javascript:/tel:/data:/about:/sms:)
        let lowerPath = pathPart.lowercased()
        for blocked in blockedSchemePrefixes where lowerPath.hasPrefix(blocked) {
            return .ignored
        }
        if let schemeRange = pathPart.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) {
            let matchedScheme = pathPart[schemeRange].lowercased()
            if matchedScheme != "file://" {
                return .ignored
            }
        }

        // Step 5: Strip file:// (rejecting non-empty non-localhost host) and percent-decode ALL remote paths
        if lowerPath.hasPrefix("file://") {
            let afterScheme = String(pathPart.dropFirst("file://".count))
            if afterScheme.hasPrefix("/") {
                pathPart = afterScheme
            } else if afterScheme.lowercased().hasPrefix("localhost/") {
                pathPart = String(afterScheme.dropFirst("localhost".count))
            } else {
                // Non-local host (e.g. file://remote-host/a.md) -> ignored
                return .ignored
            }
        }

        if let decoded = pathPart.removingPercentEncoding {
            pathPart = decoded
        }
        guard !pathPart.isEmpty else { return .ignored }

        // Step 6: Resolve relative path against sessionCwd -> serverDefaultCwd -> "~",
        // then lexically normalize `.` and `..` without ever popping leading `/` or `~`.
        let originalHadTrailingSlash = pathPart.hasSuffix("/")
        let isRootOrHome = (pathPart == "/" || pathPart == "~" || pathPart == "~/")
        let prefersDirectory = isRootOrHome || originalHadTrailingSlash

        let combined: String
        if pathPart.hasPrefix("/") || pathPart == "~" || pathPart.hasPrefix("~/") {
            combined = pathPart
        } else {
            let base = resolveBaseDirectory(sessionCwd: sessionCwd, serverDefaultCwd: serverDefaultCwd)
            if base == "/" {
                combined = "/" + pathPart
            } else if base == "~" {
                combined = "~/" + pathPart
            } else if base.hasSuffix("/") {
                combined = base + pathPart
            } else {
                combined = base + "/" + pathPart
            }
        }

        let normalized = lexicalNormalize(combined)
        return .remotePath(
            resolvedPath: normalized,
            prefersDirectory: prefersDirectory || normalized == "/" || normalized == "~",
            startLine: startLine,
            endLine: endLine
        )
    }

    private static func resolveBaseDirectory(sessionCwd: String, serverDefaultCwd: String) -> String {
        let s = sessionCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        let d = serverDefaultCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { return d }
        return "~"
    }

    private static func parseLineFragment(_ fragment: String) -> (startLine: Int, endLine: Int?)? {
        let pattern = #"^L(\d+)(?:C\d+)?(?:-L?(\d+)(?:C\d+)?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(fragment.startIndex..., in: fragment)
        guard let match = regex.firstMatch(in: fragment, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let r1 = Range(match.range(at: 1), in: fragment),
              let startLine = Int(fragment[r1]) else {
            return nil
        }
        if match.numberOfRanges >= 3,
           match.range(at: 2).location != NSNotFound,
           let r2 = Range(match.range(at: 2), in: fragment),
           let endLine = Int(fragment[r2]),
           endLine != startLine {
            return (startLine, endLine)
        }
        return (startLine, nil)
    }

    private static func matchTrailingColonLine(in value: String) -> (prefix: String, line: Int)? {
        let pattern = #":(\d+)(?::\d+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: nsRange),
              let fullRange = Range(match.range(at: 0), in: value),
              let lineRange = Range(match.range(at: 1), in: value),
              let lineNum = Int(value[lineRange]) else {
            return nil
        }
        let prefix = String(value[..<fullRange.lowerBound])
        // Guard against stripping scheme-only prefix like "file:"
        guard !prefix.isEmpty, !prefix.hasSuffix("://") else { return nil }
        return (prefix, lineNum)
    }

    private static func lexicalNormalize(_ path: String) -> String {
        if path == "/" { return "/" }
        if path == "~" || path == "~/" { return "~" }

        let isHomeAnchored = path.hasPrefix("~/")
        let isAbsolute = path.hasPrefix("/")
        let body: Substring
        if isHomeAnchored {
            body = path.dropFirst(2)
        } else if isAbsolute {
            body = path.dropFirst(1)
        } else {
            body = Substring(path)
        }

        var stack: [String] = []
        for rawPart in body.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(rawPart)
            if part == "." {
                continue
            } else if part == ".." {
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if isHomeAnchored {
                    // Preserve `~/../...` for bridge `expandHomePath` + `path.resolve`; never pop `~`
                    stack.append("..")
                }
                // For root-anchored `/`, popping at root is a no-op (never pop `/`)
            } else {
                stack.append(part)
            }
        }

        if isHomeAnchored {
            return stack.isEmpty ? "~" : "~/" + stack.joined(separator: "/")
        }
        if isAbsolute {
            return "/" + stack.joined(separator: "/")
        }
        return stack.joined(separator: "/")
    }
}
