import SwiftUI
import ACPClient
import UIKit

/// Unified read-only file preview view (T5 / SD-4.3 & SD-4.4).
/// Intentionally does NOT embed a `NavigationStack` so `RemoteFileBrowserSheet` can push it
/// without double navigation bars. Use `RemoteFilePreviewSheet` for standalone `.sheet` presentation.
struct RemoteFilePreviewView: View {
    enum RenderMode: String, CaseIterable {
        case rendered = "rendered"
        case source = "source"

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .rendered:
                return "Preview"
            case .source:
                return "Source"
            }
        }
    }

    let filePath: String
    let knownFileSize: Int64?
    let lineAnchorHint: String?
    let onOpenAsDirectory: ((String) -> Void)?
    let readFile: (String) async throws -> NonlocalFsReadFileResult?
    let mermaidSVGProvider: ((String, Bool) async -> Result<String, Error>)?

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @State private var result: NonlocalFsReadFileResult?
    @State private var errorInfo: RemoteFilePreviewErrorInfo?
    @State private var isLoading: Bool = true
    @State private var renderMode: RenderMode = .rendered
    @State private var wrapLines: Bool = true
    @State private var copied: Bool = false
    @State private var decodedImage: ImageDownsampler.DecodedImageResult?
    @State private var imageResetToken: Int = 0
    @State private var renderedMarkdownHTML: String?

    init(
        filePath: String,
        knownFileSize: Int64? = nil,
        lineAnchorHint: String? = nil,
        onOpenAsDirectory: ((String) -> Void)? = nil,
        readFile: @escaping (String) async throws -> NonlocalFsReadFileResult?,
        mermaidSVGProvider: ((String, Bool) async -> Result<String, Error>)? = nil
    ) {
        self.filePath = filePath
        self.knownFileSize = knownFileSize
        self.lineAnchorHint = lineAnchorHint
        self.onOpenAsDirectory = onOpenAsDirectory
        self.readFile = readFile
        self.mermaidSVGProvider = mermaidSVGProvider
    }

    private var fileName: String {
        if let name = result?.name, !name.isEmpty { return name }
        let last = (filePath as NSString).lastPathComponent
        return last.isEmpty ? filePath : last
    }

    private var previewKind: RemoteFilePreviewKind? {
        guard let result else { return nil }
        return RemoteFilePreviewKind.classify(result: result)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorInfo {
                errorCard(errorInfo)
            } else if isLoading && result == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading file…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result, let kind = previewKind {
                if let hint = lineAnchorHint, !hint.isEmpty {
                    lineAnchorBanner(hint)
                }
                if result.truncated {
                    truncatedBanner(size: Int64(result.size))
                }
                previewContent(for: result, kind: kind)
            }
        }
        .navigationTitle(fileName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            toolbarControls
        }
        .task(id: filePath) {
            await loadFile()
        }
        .task(id: "\(filePath)::\(colorScheme == .dark ? "dark" : "light")::\(result?.content.hashValue ?? 0)") {
            await rebuildMarkdownHTMLIfNeeded()
        }
    }

    @ToolbarContentBuilder
    private var toolbarControls: some ToolbarContent {
        if let result, let kind = previewKind, errorInfo == nil {
            switch kind {
            case .markdown, .html:
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        Picker("Mode", selection: $renderMode) {
                            ForEach(RenderMode.allCases, id: \.self) { mode in
                                Text(mode.localizedTitle).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .accessibilityIdentifier("file-preview-mode-picker")

                        if renderMode == .source {
                            copyButton(text: result.content)
                        }
                    }
                }
            case .plainText:
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 10) {
                        Button {
                            wrapLines.toggle()
                        } label: {
                            Image(systemName: wrapLines ? "text.alignleft" : "arrow.left.and.right.text.vertical")
                        }
                        .accessibilityIdentifier("file-preview-wrap-toggle")
                        .accessibilityLabel(wrapLines ? Text("Disable word wrap") : Text("Enable word wrap"))

                        copyButton(text: result.content)
                    }
                }
            case .rasterImage:
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset") {
                        imageResetToken &+= 1
                    }
                    .accessibilityIdentifier("file-preview-image-reset")
                }
            case .webImage:
                ToolbarItem(placement: .primaryAction) {
                    EmptyView()
                }
            }
        }
    }

    private func copyButton(text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .accessibilityIdentifier("file-preview-copy-button")
    }

    private func lineAnchorBanner(_ hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
            Text("Reference: \(hint)")
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.blue.opacity(0.10))
        .accessibilityIdentifier("file-preview-line-anchor-banner")
    }

    private func truncatedBanner(size: Int64) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("File is \(RemoteFilePreviewFormatter.formatByteCount(size)); showing first 512 KB")
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.14))
        .accessibilityIdentifier("file-preview-truncated-banner")
    }

    @ViewBuilder
    private func previewContent(for result: NonlocalFsReadFileResult, kind: RemoteFilePreviewKind) -> some View {
        switch kind {
        case .markdown:
            if renderMode == .source {
                PlainTextPreviewRepresentable(text: result.content, wrapLines: true)
                    .accessibilityIdentifier("file-preview-source-view")
            } else {
                PreviewWebViewRepresentable(
                    html: renderedMarkdownHTML ?? MarkdownToHTMLConverter.convertToHTMLDocument(
                        markdown: result.content,
                        isDark: colorScheme == .dark
                    ),
                    allowsJavaScript: false,
                    baseURL: nil,
                    transparentBackground: false,
                    onOpenExternalURL: { url in openURL(url) }
                )
                .accessibilityIdentifier("file-preview-markdown-webview")
            }
        case .html:
            if renderMode == .source {
                PlainTextPreviewRepresentable(text: result.content, wrapLines: true)
                    .accessibilityIdentifier("file-preview-source-view")
            } else {
                PreviewWebViewRepresentable(
                    html: result.content,
                    allowsJavaScript: true,
                    baseURL: PreviewWebNavigationPolicy.localPreviewBaseURL,
                    transparentBackground: false,
                    onOpenExternalURL: { url in openURL(url) }
                )
                .accessibilityIdentifier("file-preview-html-webview")
            }
        case .plainText:
            PlainTextPreviewRepresentable(text: result.content, wrapLines: wrapLines)
                .accessibilityIdentifier("file-preview-plaintext-view")
        case .rasterImage:
            if let decoded = decodedImage {
                VStack(spacing: 0) {
                    ZoomableRasterImageView(image: decoded.image, resetToken: $imageResetToken)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Text("\(decoded.originalPixelWidth) × \(decoded.originalPixelHeight)")
                            .font(.caption2.monospacedDigit())
                        Spacer()
                        Text(RemoteFilePreviewFormatter.formatByteCount(Int64(result.size)))
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85))
                }
                .accessibilityIdentifier("file-preview-raster-image")
            } else {
                errorCard(RemoteFilePreviewFormatter.corruptedImageError)
            }
        case .webImage(let mimeType):
            ZStack {
                Color.black.ignoresSafeArea(edges: .bottom)
                PreviewWebViewRepresentable(
                    html: StandaloneWebImageHTMLBuilder.buildHTML(base64: result.content, mimeType: mimeType),
                    allowsJavaScript: false,
                    baseURL: nil,
                    transparentBackground: true,
                    onOpenExternalURL: { url in openURL(url) }
                )
            }
            .accessibilityIdentifier("file-preview-web-image")
        }
    }

    private func errorCard(_ info: RemoteFilePreviewErrorInfo) -> some View {
        VStack(spacing: 12) {
            Image(systemName: info.isDirectory ? "folder.fill" : "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(info.title)
                .font(.headline)
                .accessibilityIdentifier("file-preview-error-title")
            Text(info.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("file-preview-error-card")
    }

    private func loadFile() async {
        isLoading = true
        errorInfo = nil
        decodedImage = nil
        renderedMarkdownHTML = nil
        do {
            guard let fetched = try await readFile(filePath) else {
                isLoading = false
                errorInfo = .init(
                    title: String(localized: "Failed to read file"),
                    detail: String(localized: "The server did not return file content."),
                    isDirectory: false
                )
                return
            }
            result = fetched
            if RemoteFilePreviewKind.classify(result: fetched) == .rasterImage {
                if let rawData = Data(base64Encoded: fetched.content, options: .ignoreUnknownCharacters) {
                    let maxDim: CGFloat = {
                        #if canImport(UIKit)
                        let screen = UIScreen.main.bounds
                        let scale = UIScreen.main.scale
                        return max(screen.width, screen.height) * scale * 2.0
                        #else
                        return 2560
                        #endif
                    }()
                    if let decoded = ImageDownsampler.decodeDownsampled(data: rawData, maxPixelSize: maxDim) {
                        decodedImage = decoded
                    } else {
                        errorInfo = RemoteFilePreviewFormatter.corruptedImageError
                    }
                } else {
                    errorInfo = RemoteFilePreviewFormatter.corruptedImageError
                }
            }
            isLoading = false
        } catch {
            let mapped = RemoteFilePreviewFormatter.mapError(error, knownFileSize: knownFileSize)
            if mapped.isDirectory, let onOpenAsDirectory {
                isLoading = false
                onOpenAsDirectory(filePath)
                return
            }
            isLoading = false
            errorInfo = mapped
        }
    }

    private func rebuildMarkdownHTMLIfNeeded() async {
        guard let result, RemoteFilePreviewKind.classify(result: result) == .markdown else { return }
        let isDark = (colorScheme == .dark)
        guard let provider = mermaidSVGProvider else {
            renderedMarkdownHTML = MarkdownToHTMLConverter.convertToHTMLDocument(
                markdown: result.content,
                isDark: isDark
            )
            return
        }

        // Pre-render all mermaid fenced blocks via the shared offline MermaidRenderer
        let blocks = Self.extractMermaidBlocks(from: result.content)
        var renderedResults: [Int: Result<String, Error>] = [:]
        for (idx, source) in blocks.enumerated() {
            if Task.isCancelled { return }
            renderedResults[idx] = await provider(source, isDark)
        }
        if Task.isCancelled { return }

        renderedMarkdownHTML = MarkdownToHTMLConverter.convertToHTMLDocument(
            markdown: result.content,
            isDark: isDark,
            mermaidRenderer: { source, idx in
                switch renderedResults[idx] {
                case .success(let svg):
                    let deduped = MarkdownToHTMLConverter.deduplicateSVGIds(svg, prefix: "mdm\(idx)")
                    return "<div class=\"mermaid-diagram\">\(deduped)</div>"
                case .failure(let err):
                    let errorPrefix = MarkdownToHTMLConverter.escapeHTML(String(localized: "Mermaid rendering failed"))
                    let escapedErr = MarkdownToHTMLConverter.escapeHTML(err.localizedDescription)
                    let escapedSrc = MarkdownToHTMLConverter.escapeHTML(source)
                    return """
                    <div class="markdown-prose">
                      <div class="mermaid-error-banner">\(errorPrefix): \(escapedErr)</div>
                      <pre><code class="language-mermaid">\(escapedSrc)</code></pre>
                    </div>
                    """
                case .none:
                    return "<div class=\"markdown-prose\"><pre><code class=\"language-mermaid\">\(MarkdownToHTMLConverter.escapeHTML(source))</code></pre></div>"
                }
            }
        )
    }

    private static func extractMermaidBlocks(from markdown: String) -> [String] {
        var blocks: [String] = []
        _ = MarkdownToHTMLConverter.convertBody(markdown: markdown) { src, _ in
            blocks.append(src)
            return ""
        }
        return blocks
    }
}

/// Standalone sheet wrapper for `RemoteFilePreviewView` (used by T6 chat path links).
struct RemoteFilePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let filePath: String
    let knownFileSize: Int64?
    let lineAnchorHint: String?
    let onOpenAsDirectory: ((String) -> Void)?
    let readFile: (String) async throws -> NonlocalFsReadFileResult?
    let mermaidSVGProvider: ((String, Bool) async -> Result<String, Error>)?

    init(
        filePath: String,
        knownFileSize: Int64? = nil,
        lineAnchorHint: String? = nil,
        onOpenAsDirectory: ((String) -> Void)? = nil,
        readFile: @escaping (String) async throws -> NonlocalFsReadFileResult?,
        mermaidSVGProvider: ((String, Bool) async -> Result<String, Error>)? = nil
    ) {
        self.filePath = filePath
        self.knownFileSize = knownFileSize
        self.lineAnchorHint = lineAnchorHint
        self.onOpenAsDirectory = onOpenAsDirectory
        self.readFile = readFile
        self.mermaidSVGProvider = mermaidSVGProvider
    }

    var body: some View {
        NavigationStack {
            RemoteFilePreviewView(
                filePath: filePath,
                knownFileSize: knownFileSize,
                lineAnchorHint: lineAnchorHint,
                onOpenAsDirectory: onOpenAsDirectory,
                readFile: readFile,
                mermaidSVGProvider: mermaidSVGProvider
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("file-preview-close-button")
                }
            }
        }
    }
}
