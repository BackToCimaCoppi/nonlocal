import Foundation

/// Pure-Foundation linear scanner that turns explicit bare paths and backtick inline paths
/// into Markdown links before `MarkdownParser().parse(...)` (T6 / SD-5.1 / AC-501 & AC-502).
enum ChatPathLinkPreprocessor {
    private static let trailingPunctuation: Set<Character> = [
        "。", "，", "；", "、", "：", "？", "！", "）", "】", "》", "」", "』",
        ")", "]", ">", "\"", "'", ",", ";", ":", "?", "!"
    ]

    private static let commonFileExtensions: Set<String> = [
        "md", "markdown", "txt", "log", "json", "yaml", "yml", "toml", "xml", "csv",
        "html", "htm", "css", "scss", "js", "mjs", "cjs", "ts", "tsx", "jsx",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "py", "rb", "go", "rs",
        "java", "kt", "kts", "sh", "zsh", "bash", "sql", "plist", "xcconfig",
        "pbxproj", "env", "ini", "cfg", "conf", "lock", "gradle", "makefile",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "svg"
    ]

    static func preprocess(_ markdown: String) -> String {
        guard !markdown.isEmpty else { return markdown }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var outputLines: [String] = []
        outputLines.reserveCapacity(lines.count)

        var activeFenceChar: Character?
        var activeFenceLength: Int = 0

        for line in lines {
            if let fenceChar = activeFenceChar {
                outputLines.append(line)
                if isFenceClose(line, char: fenceChar, minLength: activeFenceLength) {
                    activeFenceChar = nil
                    activeFenceLength = 0
                }
                continue
            }

            if let open = parseFenceOpen(line) {
                activeFenceChar = open.char
                activeFenceLength = open.length
                outputLines.append(line)
                continue
            }

            outputLines.append(processLine(line))
        }

        return outputLines.joined(separator: "\n")
    }

    private static func parseFenceOpen(_ line: String) -> (char: Character, length: Int)? {
        var idx = line.startIndex
        var spaces = 0
        while idx < line.endIndex && line[idx] == " " && spaces < 3 {
            spaces += 1
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return nil }
        let ch = line[idx]
        guard ch == "`" || ch == "~" else { return nil }
        var count = 0
        while idx < line.endIndex && line[idx] == ch {
            count += 1
            idx = line.index(after: idx)
        }
        guard count >= 3 else { return nil }
        let rest = line[idx...]
        if ch == "`" && rest.contains("`") { return nil }
        return (ch, count)
    }

    private static func isFenceClose(_ line: String, char: Character, minLength: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minLength else { return false }
        return trimmed.allSatisfy { $0 == char }
    }

    private static func processLine(_ line: String) -> String {
        var result = ""
        result.reserveCapacity(line.count)

        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]

            // 1. Skip existing Markdown link [label](dest)
            if ch == "[", let linkEnd = matchExistingMarkdownLink(in: line, from: i) {
                result += line[i..<linkEnd]
                i = linkEnd
                continue
            }

            // 2. Skip autolink <...>
            if ch == "<", let angleEnd = matchAngleAutolink(in: line, from: i) {
                result += line[i..<angleEnd]
                i = angleEnd
                continue
            }

            // 3. Skip inline code `...` or rewrite backtick path to [`raw`](encoded)
            if ch == "`" {
                let tickStart = i
                var tickCount = 0
                while i < line.endIndex && line[i] == "`" {
                    tickCount += 1
                    i = line.index(after: i)
                }
                let delimiter = String(repeating: "`", count: tickCount)
                if let closeRange = line[i...].range(of: delimiter) {
                    let inner = String(line[i..<closeRange.lowerBound])
                    if tickCount == 1, isLikelyBacktickPath(inner) {
                        let encoded = encodeMarkdownDestination(inner)
                        result += "[`\(inner)`](\(encoded))"
                    } else {
                        result += line[tickStart..<closeRange.upperBound]
                    }
                    i = closeRange.upperBound
                    continue
                } else {
                    result += line[tickStart..<i]
                    continue
                }
            }

            // 4. Skip web URLs (http://, https://, ftp://, mailto:)
            if isBoundaryBefore(in: line, at: i), let urlEnd = matchExternalURL(in: line, from: i) {
                result += line[i..<urlEnd]
                i = urlEnd
                continue
            }

            // 5. Bare path (file://..., ~/..., or multi-segment /a/b...)
            if isBoundaryBefore(in: line, at: i), let (pathEnd, candidate) = matchBarePath(in: line, from: i) {
                let encoded = encodeMarkdownDestination(candidate)
                result += "[\(candidate)](\(encoded))"
                i = pathEnd
                continue
            }

            result.append(ch)
            i = line.index(after: i)
        }

        return result
    }

    private static func matchExistingMarkdownLink(in line: String, from start: String.Index) -> String.Index? {
        var idx = line.index(after: start)
        var bracketDepth = 1
        while idx < line.endIndex && bracketDepth > 0 {
            let c = line[idx]
            if c == "\\" {
                idx = line.index(after: idx)
                if idx < line.endIndex { idx = line.index(after: idx) }
                continue
            }
            if c == "[" { bracketDepth += 1 }
            else if c == "]" { bracketDepth -= 1 }
            idx = line.index(after: idx)
        }
        guard bracketDepth == 0, idx < line.endIndex, line[idx] == "(" else { return nil }
        idx = line.index(after: idx)
        var parenDepth = 1
        while idx < line.endIndex && parenDepth > 0 {
            let c = line[idx]
            if c == "\\" {
                idx = line.index(after: idx)
                if idx < line.endIndex { idx = line.index(after: idx) }
                continue
            }
            if c == "(" { parenDepth += 1 }
            else if c == ")" { parenDepth -= 1 }
            idx = line.index(after: idx)
        }
        return parenDepth == 0 ? idx : nil
    }

    private static func matchAngleAutolink(in line: String, from start: String.Index) -> String.Index? {
        let after = line.index(after: start)
        guard let close = line[after...].firstIndex(of: ">") else { return nil }
        let inner = line[after..<close]
        guard !inner.isEmpty, !inner.contains(where: { $0.isWhitespace }) else { return nil }
        if inner.contains("://") || inner.lowercased().hasPrefix("mailto:") {
            return line.index(after: close)
        }
        return nil
    }

    private static func isBoundaryBefore(in line: String, at index: String.Index) -> Bool {
        guard index > line.startIndex else { return true }
        let prev = line[line.index(before: index)]
        if prev.isWhitespace { return true }
        if prev == "(" || prev == "[" || prev == "{" || prev == "（" || prev == "【"
            || prev == "、" || prev == "，" || prev == "：" || prev == "；" || prev == "。"
            || prev == "," || prev == ":" || prev == ";" || prev == "\"" || prev == "'" {
            return true
        }
        // CJK character immediately preceding a path (e.g. "见/Users/a/foo.md")
        if let scalar = prev.unicodeScalars.first, scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
            return true
        }
        return false
    }

    private static func matchExternalURL(in line: String, from start: String.Index) -> String.Index? {
        let rest = line[start...]
        let lowerPrefix = rest.prefix(8).lowercased()
        guard lowerPrefix.hasPrefix("https://")
                || lowerPrefix.hasPrefix("http://")
                || lowerPrefix.hasPrefix("ftp://")
                || lowerPrefix.hasPrefix("mailto:") else {
            return nil
        }
        var end = start
        while end < line.endIndex && !line[end].isWhitespace && !isStopBoundary(line[end]) {
            end = line.index(after: end)
        }
        return end > start ? end : nil
    }

    private static func matchBarePath(in line: String, from start: String.Index) -> (String.Index, String)? {
        let rest = line[start...]
        let isFileURL = rest.prefix(7).lowercased() == "file://"
        let isHomePath = rest.hasPrefix("~/")
        let isAbsPath = rest.hasPrefix("/") && !rest.hasPrefix("//")

        guard isFileURL || isHomePath || isAbsPath else { return nil }

        var end = start
        while end < line.endIndex {
            let c = line[end]
            if c.isWhitespace || isStopBoundary(c) {
                break
            }
            end = line.index(after: end)
        }

        // Trim trailing CJK/ASCII punctuation and sentence-ending "."
        var trimmedEnd = end
        while trimmedEnd > start {
            let prevIdx = line.index(before: trimmedEnd)
            let lastChar = line[prevIdx]
            if trailingPunctuation.contains(lastChar) || lastChar == "." {
                trimmedEnd = prevIdx
            } else {
                break
            }
        }

        guard trimmedEnd > start else { return nil }
        let candidate = String(line[start..<trimmedEnd])

        if isFileURL {
            guard candidate.count > "file://".count else { return nil }
            return (trimmedEnd, candidate)
        }
        if isHomePath {
            guard candidate.count > 2 else { return nil }
            return (trimmedEnd, candidate)
        }
        // Absolute path: require at least 2 path segments (/a/b) to avoid matching single "/foo" slash commands
        let stripped = stripLineOrHashSuffix(candidate)
        let components = stripped.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }
        return (trimmedEnd, candidate)
    }

    private static func isStopBoundary(_ ch: Character) -> Bool {
        ch == "、" || ch == "，" || ch == "。" || ch == "；" || ch == "：" || ch == "？" || ch == "！"
            || ch == "（" || ch == "）" || ch == "【" || ch == "】" || ch == "《" || ch == "》"
            || ch == "「" || ch == "」" || ch == "`" || ch == "<" || ch == ">"
    }

    private static func isLikelyBacktickPath(_ raw: String) -> Bool {
        guard !raw.isEmpty else { return false }
        guard !raw.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://") || lower.hasPrefix("mailto:") {
            return false
        }
        if lower.hasPrefix("file://") || raw.hasPrefix("~/") || raw.hasPrefix("./") || raw.hasPrefix("../") {
            return raw.count > 2
        }

        let core = stripLineOrHashSuffix(raw)
        if core.hasPrefix("/") {
            let parts = core.split(separator: "/", omittingEmptySubsequences: true)
            return parts.count >= 2
        }

        if core.contains("/") {
            // Reject numeric ratios & dates like 1/2, 2026/11/19
            let parts = core.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return false }
            let allNumeric = parts.allSatisfy { part in part.allSatisfy { $0.isNumber } }
            if allNumeric { return false }
            return true
        }

        // Single-segment filename with known extension (e.g. App.swift:42, README.md)
        if let dotIdx = core.lastIndex(of: "."), dotIdx > core.startIndex {
            let ext = String(core[core.index(after: dotIdx)...]).lowercased()
            if commonFileExtensions.contains(ext) {
                return true
            }
        }
        return false
    }

    private static func stripLineOrHashSuffix(_ raw: String) -> String {
        var value = raw
        if let hashIdx = value.firstIndex(of: "#") {
            value = String(value[..<hashIdx])
        }
        if let range = value.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            value = String(value[..<range.lowerBound])
        }
        return value
    }

    /// Encodes CommonMark-sensitive characters (parentheses, spaces, non-ASCII) while NEVER encoding `#`.
    static func encodeMarkdownDestination(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: "/:~.-_@#?=&+,;!$'*")
        allowed.remove(charactersIn: "()<> \"\\[]")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
