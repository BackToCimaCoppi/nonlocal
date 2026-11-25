import Foundation
import SwiftUI
import WebKit
import ImageIO
import ACPClient
import UIKit

// MARK: - Preview Kind Routing (AC-403)

enum RemoteFilePreviewKind: Equatable {
    case markdown
    case html
    case plainText
    case rasterImage
    case webImage(mimeType: String) // image/gif, image/svg+xml

    static func classify(result: NonlocalFsReadFileResult) -> RemoteFilePreviewKind {
        let mime = result.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch result.kind {
        case .image:
            if mime == "image/gif" || mime == "image/svg+xml" {
                return .webImage(mimeType: mime)
            }
            let lowerName = result.name.lowercased()
            if lowerName.hasSuffix(".gif") {
                return .webImage(mimeType: "image/gif")
            }
            if lowerName.hasSuffix(".svg") {
                return .webImage(mimeType: "image/svg+xml")
            }
            return .rasterImage
        case .text:
            if mime == "text/markdown" {
                return .markdown
            }
            if mime == "text/html" {
                return .html
            }
            let lowerName = result.name.lowercased()
            if lowerName.hasSuffix(".md") || lowerName.hasSuffix(".markdown") {
                return .markdown
            }
            if lowerName.hasSuffix(".html") || lowerName.hasSuffix(".htm") {
                return .html
            }
            return .plainText
        }
    }
}

// MARK: - Error Mapping (AC-405)

struct RemoteFilePreviewErrorInfo: Equatable {
    let title: String
    let detail: String
    let isDirectory: Bool
}

enum RemoteFilePreviewFormatter {
    static func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func mapError(
        _ error: Error,
        knownFileSize: Int64?
    ) -> RemoteFilePreviewErrorInfo {
        let sizeSuffix: String = {
            if let knownFileSize, knownFileSize >= 0 {
                return String(localized: " (approx. \(formatByteCount(knownFileSize)))")
            }
            return ""
        }()

        if let serviceError = error as? ACPServiceError, let code = serviceError.rpcCode {
            let serverMsg: String = {
                if case .rpc(_, let rpcError) = serviceError {
                    return rpcError.message
                }
                return serviceError.localizedDescription
            }()
            switch code {
            case NonlocalFsErrorCode.notFound.rawValue:
                return .init(title: String(localized: "File Not Found"), detail: String(localized: "This path could not be found on the host; it may have been moved or deleted."), isDirectory: false)
            case NonlocalFsErrorCode.permissionDenied.rawValue:
                return .init(title: String(localized: "Permission Denied"), detail: String(localized: "The current bridge process does not have permission to read this file."), isDirectory: false)
            case NonlocalFsErrorCode.isDirectory.rawValue:
                return .init(title: String(localized: "This Is a Directory"), detail: String(localized: "Use the directory browser to view its contents."), isDirectory: true)
            case NonlocalFsErrorCode.unsupportedBinary.rawValue:
                let extra = !sizeSuffix.isEmpty ? sizeSuffix : (serverMsg.isEmpty ? "" : ": \(serverMsg)")
                return .init(title: String(localized: "Binary File Preview Unsupported"), detail: String(localized: "Only plain text, Markdown, HTML, and common images are supported\(extra)."), isDirectory: false)
            case NonlocalFsErrorCode.fileTooLarge.rawValue:
                let extra = !sizeSuffix.isEmpty ? sizeSuffix : (serverMsg.isEmpty ? "" : ": \(serverMsg)")
                return .init(title: String(localized: "Image Exceeds 10 MB Limit"), detail: String(localized: "Online preview is not supported for images larger than 10 MB\(extra)."), isDirectory: false)
            case NonlocalFsErrorCode.invalidParams.rawValue:
                return .init(title: String(localized: "Invalid File Path"), detail: String(localized: "Please provide a valid absolute path starting with / or ~."), isDirectory: false)
            default:
                return .init(title: String(localized: "Failed to Read File"), detail: serverMsg, isDirectory: false)
            }
        }
        return .init(title: String(localized: "Failed to Read File"), detail: error.localizedDescription, isDirectory: false)
    }

    static var corruptedImageError: RemoteFilePreviewErrorInfo {
        .init(title: String(localized: "Image Decoding Failed"), detail: String(localized: "The image file may be corrupted or in an unsupported format."), isDirectory: false)
    }
}

// MARK: - Markdown to Semantic HTML Converter (AC-403 & M5 Mermaid hook)

enum MarkdownToHTMLConverter {
    struct MermaidBlockReplacement {
        let html: String
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func sanitizeHref(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") {
            return escapeHTML(trimmed)
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            return escapeHTML(trimmed)
        }
        return nil
    }

    /// Deduplicates DOM `id="..."` and `url(#...)` references inside an inline SVG
    /// so repeated Mermaid diagrams in the same `.md` page never collide (AC-604).
    static func deduplicateSVGIds(_ svg: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return svg }
        let idPattern = try? NSRegularExpression(pattern: #"\bid="([^"]+)""#, options: [])
        let nsRange = NSRange(svg.startIndex..., in: svg)
        var ids: [String] = []
        if let matches = idPattern?.matches(in: svg, options: [], range: nsRange) {
            var seen: Set<String> = []
            for m in matches where m.numberOfRanges >= 2 {
                if let r = Range(m.range(at: 1), in: svg) {
                    let val = String(svg[r])
                    if !seen.contains(val) {
                        seen.insert(val)
                        ids.append(val)
                    }
                }
            }
        }
        guard !ids.isEmpty else { return svg }
        // Sort longest first to avoid partial prefix replacement
        let sortedIds = ids.sorted { $0.count > $1.count }
        var output = svg
        for original in sortedIds {
            let scoped = "\(prefix)_\(original)"
            output = output.replacingOccurrences(of: "id=\"\(original)\"", with: "id=\"\(scoped)\"")
            output = output.replacingOccurrences(of: "url(#\(original))", with: "url(#\(scoped))")
            output = output.replacingOccurrences(of: "href=\"#\(original)\"", with: "href=\"#\(scoped)\"")
            output = output.replacingOccurrences(of: "xlink:href=\"#\(original)\"", with: "xlink:href=\"#\(scoped)\"")
            output = output.replacingOccurrences(of: "#\(original) ", with: "#\(scoped) ")
            output = output.replacingOccurrences(of: "#\(original){", with: "#\(scoped){")
            output = output.replacingOccurrences(of: "#\(original),", with: "#\(scoped),")
        }
        return output
    }

    static func convertToHTMLDocument(
        markdown: String,
        isDark: Bool = false,
        mermaidRenderer: ((String, Int) -> String)? = nil
    ) -> String {
        let bodyHTML = convertBody(markdown: markdown, mermaidRenderer: mermaidRenderer)
        let bg = isDark ? "#111317" : "#ffffff"
        let fg = isDark ? "#e6e8ec" : "#1f2328"
        let muted = isDark ? "#9aa3b2" : "#656d76"
        let border = isDark ? "#2d333b" : "#d0d7de"
        let codeBg = isDark ? "#1b1f26" : "#f6f8fa"
        let linkColor = isDark ? "#58a6ff" : "#0969da"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
        <style>
          body { margin: 0; padding: 16px; background: \(bg); color: \(fg); font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; line-height: 1.6; word-wrap: break-word; }
          .markdown-prose h1, .markdown-prose h2, .markdown-prose h3, .markdown-prose h4, .markdown-prose h5, .markdown-prose h6 { margin: 1.1em 0 0.5em; font-weight: 700; line-height: 1.25; }
          .markdown-prose h1 { font-size: 1.75em; border-bottom: 1px solid \(border); padding-bottom: 0.25em; }
          .markdown-prose h2 { font-size: 1.45em; border-bottom: 1px solid \(border); padding-bottom: 0.2em; }
          .markdown-prose h3 { font-size: 1.22em; }
          .markdown-prose h4 { font-size: 1.05em; }
          .markdown-prose h5 { font-size: 0.95em; }
          .markdown-prose h6 { font-size: 0.88em; color: \(muted); }
          .markdown-prose p { margin: 0.65em 0; }
          .markdown-prose a { color: \(linkColor); text-decoration: none; }
          .markdown-prose blockquote { margin: 0.8em 0; padding: 0.2em 1em; border-left: 3px solid \(border); color: \(muted); }
          .markdown-prose pre { background: \(codeBg); padding: 12px; border-radius: 8px; overflow-x: auto; font-size: 0.88em; }
          .markdown-prose code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: \(codeBg); padding: 0.12em 0.35em; border-radius: 4px; font-size: 0.9em; }
          .markdown-prose pre code { background: transparent; padding: 0; }
          .markdown-prose ul, .markdown-prose ol { padding-left: 1.5em; margin: 0.6em 0; }
          .markdown-prose table { border-collapse: collapse; width: 100%; margin: 0.8em 0; display: block; overflow-x: auto; }
          .markdown-prose th, .markdown-prose td { border: 1px solid \(border); padding: 6px 10px; text-align: left; }
          .markdown-prose th { background: \(codeBg); font-weight: 600; }
          .markdown-prose hr { border: none; border-top: 1px solid \(border); margin: 1.2em 0; }
          .mermaid-diagram { margin: 12px 0; padding: 10px; border-radius: 10px; background: \(codeBg); overflow-x: auto; text-align: center; }
          .mermaid-diagram svg { max-width: 100%; height: auto; }
          .mermaid-error-banner { color: #d1242f; background: rgba(209,36,47,0.10); border-radius: 6px; padding: 6px 10px; font-size: 0.85em; margin-bottom: 6px; }
        </style>
        </head>
        <body>
        \(bodyHTML)
        </body>
        </html>
        """
    }

    static func convertBody(
        markdown: String,
        mermaidRenderer: ((String, Int) -> String)? = nil
    ) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var htmlParts: [String] = []
        var proseBuffer: [String] = []
        var mermaidIndex = 0

        func flushProse() {
            guard !proseBuffer.isEmpty else { return }
            htmlParts.append("<div class=\"markdown-prose\">\(proseBuffer.joined(separator: "\n"))</div>")
            proseBuffer.removeAll()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block (``` or ~~~)
            if let fence = parseFenceOpen(line) {
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if isFenceClose(lines[i], char: fence.char, minLength: fence.length) {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                let codeBody = codeLines.joined(separator: "\n")
                if fence.language.lowercased() == "mermaid", let mermaidRenderer {
                    flushProse()
                    let rendered = mermaidRenderer(codeBody, mermaidIndex)
                    mermaidIndex += 1
                    htmlParts.append(rendered)
                } else {
                    let langAttr = fence.language.isEmpty ? "" : " class=\"language-\(escapeHTML(fence.language))\""
                    proseBuffer.append("<pre><code\(langAttr)>\(escapeHTML(codeBody))</code></pre>")
                }
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // ATX Headings H1..H6
            if let (level, headingText) = parseHeading(trimmed) {
                proseBuffer.append("<h\(level)>\(renderInline(headingText))</h\(level)>")
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                proseBuffer.append("<hr>")
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let qt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard qt.hasPrefix(">") else { break }
                    var content = String(qt.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoteLines.append(content)
                    i += 1
                }
                proseBuffer.append("<blockquote><p>\(renderInline(quoteLines.joined(separator: "<br>")))</p></blockquote>")
                continue
            }

            // GFM Table
            if i + 1 < lines.count && isTableHeader(header: line, separator: lines[i + 1]) {
                let headers = splitTableRow(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !rowLine.isEmpty && rowLine.contains("|") else { break }
                    rows.append(splitTableRow(rowLine))
                    i += 1
                }
                var table = "<table><thead><tr>"
                for h in headers {
                    table += "<th>\(renderInline(h))</th>"
                }
                table += "</tr></thead><tbody>"
                for r in rows {
                    table += "<tr>"
                    for cell in r {
                        table += "<td>\(renderInline(cell))</td>"
                    }
                    table += "</tr>"
                }
                table += "</tbody></table>"
                proseBuffer.append(table)
                continue
            }

            // Unordered list
            if isUnorderedListItem(trimmed) != nil {
                var items: [String] = []
                while i < lines.count, let item = isUnorderedListItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append("<li>\(renderInline(item))</li>")
                    i += 1
                }
                proseBuffer.append("<ul>\(items.joined())</ul>")
                continue
            }

            // Ordered list
            if isOrderedListItem(trimmed) != nil {
                var items: [String] = []
                while i < lines.count, let item = isOrderedListItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append("<li>\(renderInline(item))</li>")
                    i += 1
                }
                proseBuffer.append("<ol>\(items.joined())</ol>")
                continue
            }

            // Paragraph
            var paraLines: [String] = []
            while i < lines.count {
                let current = lines[i]
                let curTrimmed = current.trimmingCharacters(in: .whitespaces)
                if curTrimmed.isEmpty
                    || parseFenceOpen(current) != nil
                    || parseHeading(curTrimmed) != nil
                    || curTrimmed.hasPrefix(">")
                    || isUnorderedListItem(curTrimmed) != nil
                    || isOrderedListItem(curTrimmed) != nil {
                    break
                }
                if i + 1 < lines.count && isTableHeader(header: current, separator: lines[i + 1]) {
                    break
                }
                paraLines.append(current)
                i += 1
            }
            proseBuffer.append("<p>\(renderInline(paraLines.joined(separator: "\n")))</p>")
        }

        flushProse()
        return htmlParts.joined(separator: "\n")
    }

    private static func parseFenceOpen(_ line: String) -> (char: Character, length: Int, language: String)? {
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
        let rest = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        if ch == "`" && rest.contains("`") { return nil }
        let lang = rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return (ch, count, lang)
    }

    private static func isFenceClose(_ line: String, char: Character, minLength: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minLength else { return false }
        return trimmed.allSatisfy { $0 == char }
    }

    private static func parseHeading(_ trimmed: String) -> (Int, String)? {
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx] == "#" && level < 6 {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard level >= 1, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
        let text = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func isUnorderedListItem(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return String(trimmed.dropFirst(2))
        }
        return nil
    }

    private static func isOrderedListItem(_ trimmed: String) -> String? {
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx].isNumber {
            idx = trimmed.index(after: idx)
        }
        guard idx > trimmed.startIndex, idx < trimmed.endIndex, trimmed[idx] == "." else { return nil }
        let next = trimmed.index(after: idx)
        guard next < trimmed.endIndex, trimmed[next] == " " else { return nil }
        return String(trimmed[trimmed.index(after: next)...])
    }

    private static func isTableHeader(header: String, separator: String) -> Bool {
        guard header.contains("|") else { return false }
        let sep = separator.trimmingCharacters(in: .whitespaces)
        guard sep.contains("-") && sep.contains("|") else { return false }
        let allowed = CharacterSet(charactersIn: "|-: ")
        return sep.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func renderInline(_ text: String) -> String {
        // Escape HTML first, then handle inline code, links, bold, italic safely.
        var result = ""
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            // Inline code `...`
            if ch == "`" {
                let nextIdx = text.index(after: i)
                if let endIdx = text[nextIdx...].firstIndex(of: "`") {
                    let code = String(text[nextIdx..<endIdx])
                    result += "<code>\(escapeHTML(code))</code>"
                    i = text.index(after: endIdx)
                    continue
                }
            }
            // Markdown link [label](url)
            if ch == "[" {
                let labelStart = text.index(after: i)
                if let labelEnd = text[labelStart...].firstIndex(of: "]") {
                    let afterBracket = text.index(after: labelEnd)
                    if afterBracket < text.endIndex && text[afterBracket] == "(" {
                        let urlStart = text.index(after: afterBracket)
                        if let urlEnd = text[urlStart...].firstIndex(of: ")") {
                            let label = String(text[labelStart..<labelEnd])
                            let rawURL = String(text[urlStart..<urlEnd])
                            if let safeHref = sanitizeHref(rawURL) {
                                result += "<a href=\"\(safeHref)\">\(escapeHTML(label))</a>"
                            } else {
                                result += escapeHTML(label)
                            }
                            i = text.index(after: urlEnd)
                            continue
                        }
                    }
                }
            }
            // Bold **...**
            if ch == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if let endRange = text[start...].range(of: "**") {
                    let inner = String(text[start..<endRange.lowerBound])
                    result += "<strong>\(escapeHTML(inner))</strong>"
                    i = endRange.upperBound
                    continue
                }
            }
            result += escapeHTML(String(ch))
            i = text.index(after: i)
        }
        return result
    }
}

// MARK: - WKNavigationPolicy Pure Helper (AC-403 & Self-Heal #3)

enum PreviewWebNavigationDecision: Equatable {
    case allow
    case cancel
    case openExternally(URL)
}

enum PreviewWebNavigationPolicy {
    /// Non-network synthetic baseURL so self-contained HTML `localStorage` does not throw SecurityError
    /// under opaque `about:blank` origin while still blocking all external/relative network navigation (Self-Heal #3).
    static let localPreviewBaseURL = URL(string: "http://nonlocal.local/")!

    static func evaluate(
        url: URL?,
        isLinkActivated: Bool,
        isTargetFrameNil: Bool
    ) -> PreviewWebNavigationDecision {
        guard let url else { return .cancel }
        let scheme = (url.scheme ?? "").lowercased()

        // Allow initial local load & same-page fragment navigation
        if !isLinkActivated {
            if url.absoluteString == "about:blank" || url.absoluteString.hasPrefix("about:blank#") {
                return .allow
            }
            if url.host?.lowercased() == "nonlocal.local" && (url.path.isEmpty || url.path == "/") {
                return .allow
            }
            return .cancel
        }

        // User-activated link
        if url.absoluteString.hasPrefix("about:blank#") {
            return .allow
        }
        if url.host?.lowercased() == "nonlocal.local", url.fragment != nil, (url.path.isEmpty || url.path == "/") {
            return .allow
        }
        if (scheme == "http" || scheme == "https"), url.host?.lowercased() != "nonlocal.local" {
            // Includes target="_blank" where targetFrame == nil
            _ = isTargetFrameNil
            return .openExternally(url)
        }
        if scheme == "mailto" {
            return .openExternally(url)
        }
        return .cancel
    }
}

// MARK: - High-Resolution Raster Image Downsampler (Self-Heal #1 / AC-404)

enum ImageDownsampler {
    struct DecodedImageResult {
        let image: UIImage
        let originalPixelWidth: Int
        let originalPixelHeight: Int
        let outputPixelWidth: Int
        let outputPixelHeight: Int
    }

    static func decodeDownsampled(data: Data, maxPixelSize: CGFloat) -> DecodedImageResult? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let origW = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let origH = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0

        let clampedMax = max(64, Int(maxPixelSize.rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: clampedMax
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let outW = cgImage.width
        let outH = cgImage.height
        let platformImage = UIImage(cgImage: cgImage)
        return DecodedImageResult(
            image: platformImage,
            originalPixelWidth: origW > 0 ? origW : outW,
            originalPixelHeight: origH > 0 ? origH : outH,
            outputPixelWidth: outW,
            outputPixelHeight: outH
        )
    }
}

// MARK: - Standalone Image HTML Wrapper for GIF & Standalone Disk .svg (#衔接点-c / AC-404)

enum StandaloneWebImageHTMLBuilder {
    static func buildHTML(base64: String, mimeType: String) -> String {
        let safeMime = mimeType.lowercased()
        let safeBase64 = base64.replacingOccurrences(of: "\"", with: "")
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
        <style>
          html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: transparent; display: flex; align-items: center; justify-content: center; }
          img { max-width: 100%; max-height: 100%; object-fit: contain; display: block; }
        </style>
        </head>
        <body>
          <img src="data:\(safeMime);base64,\(safeBase64)" alt="preview">
        </body>
        </html>
        """
    }
}

// MARK: - Cross-Platform WebView & PlainText Representables (Self-Heal #2 & #3)

#if canImport(UIKit)
struct PreviewWebViewRepresentable: UIViewRepresentable {
    let html: String
    let allowsJavaScript: Bool
    let baseURL: URL?
    let transparentBackground: Bool
    let onOpenExternalURL: (URL) -> Void

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String = ""
        var lastAllowsJS: Bool = false
        var onOpenExternalURL: (URL) -> Void

        init(onOpenExternalURL: @escaping (URL) -> Void) {
            self.onOpenExternalURL = onOpenExternalURL
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            preferences.allowsContentJavaScript = lastAllowsJS
            let decision = PreviewWebNavigationPolicy.evaluate(
                url: navigationAction.request.url,
                isLinkActivated: navigationAction.navigationType == .linkActivated,
                isTargetFrameNil: navigationAction.targetFrame == nil
            )
            switch decision {
            case .allow:
                decisionHandler(.allow, preferences)
            case .cancel:
                decisionHandler(.cancel, preferences)
            case .openExternally(let url):
                onOpenExternalURL(url)
                decisionHandler(.cancel, preferences)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenExternalURL: onOpenExternalURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        if transparentBackground {
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        }
        context.coordinator.lastAllowsJS = allowsJavaScript
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenExternalURL = onOpenExternalURL
        context.coordinator.lastAllowsJS = allowsJavaScript
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }
}

struct PlainTextPreviewRepresentable: UIViewRepresentable {
    let text: String
    let wrapLines: Bool

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        applyWrapMode(to: textView, wrap: wrapLines)
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        applyWrapMode(to: textView, wrap: wrapLines)
    }

    private func applyWrapMode(to textView: UITextView, wrap: Bool) {
        if wrap {
            textView.textContainer.widthTracksTextView = true
            textView.textContainer.size = CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            textView.alwaysBounceHorizontal = false
        } else {
            textView.textContainer.widthTracksTextView = false
            textView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.alwaysBounceHorizontal = true
        }
    }
}

struct ZoomableRasterImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var resetToken: Int

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var lastResetToken: Int = 0

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                scrollView.setZoomScale(2.5, animated: true)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        context.coordinator.lastResetToken = resetToken

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            scrollView.setZoomScale(1.0, animated: true)
        }
    }
}
#endif
