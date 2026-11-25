import SwiftUI
import WebKit
import UIKit

/// Fullscreen Mermaid diagram viewer (T10 / SD-6.4 / AC-605, AC-610, AC-611, #衔接点-c).
/// Uses zero-JS HTML5 shell with inline `<svg>` (NEVER `<img src="data:image/svg+xml">`)
/// so Mermaid's HTML5 `<br>` and `<foreignObject>` render cleanly.
enum MermaidFullscreenHTMLBuilder {
    static func buildInlineSVGHTML(svg: String, isDark: Bool) -> String {
        let bg = isDark ? "#111317" : "#ffffff"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=6.0, user-scalable=yes">
        <style>
          html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: \(bg); }
          .stage { min-width: 100%; min-height: 100%; display: flex; align-items: center; justify-content: center; padding: 16px; box-sizing: border-box; }
          .stage svg { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
          <div class="stage">\(svg)</div>
        </body>
        </html>
        """
    }
}

struct MermaidFullscreenSheet: View {
    enum Mode: String, CaseIterable {
        case diagram = "rendered"
        case source = "source"

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .diagram:
                return "Diagram"
            case .source:
                return "Source"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let source: String

    @State private var mode: Mode = .diagram
    @State private var svg: String?
    @State private var errorSummary: String?
    @State private var isLoading: Bool = true
    @State private var copied: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if mode == .source {
                    PlainTextPreviewRepresentable(text: source, wrapLines: true)
                        .accessibilityIdentifier("mermaid-fullscreen-source")
                } else if let errorSummary {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text("Mermaid rendering failed: \(errorSummary)")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.10))
                        .accessibilityIdentifier("mermaid-fullscreen-error-banner")

                        PlainTextPreviewRepresentable(text: source, wrapLines: true)
                    }
                } else if let svg {
                    PreviewWebViewRepresentable(
                        html: MermaidFullscreenHTMLBuilder.buildInlineSVGHTML(
                            svg: svg,
                            isDark: colorScheme == .dark
                        ),
                        allowsJavaScript: false,
                        baseURL: nil,
                        transparentBackground: false,
                        onOpenExternalURL: { _ in }
                    )
                    .accessibilityIdentifier("mermaid-fullscreen-webview")
                } else if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Rendering diagram…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Mermaid Diagram")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("mermaid-fullscreen-close-button")
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { item in
                                Text(item.localizedTitle).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .accessibilityIdentifier("mermaid-fullscreen-mode-picker")

                        Button {
                            UIPasteboard.general.string = source
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityIdentifier("mermaid-fullscreen-copy-button")
                    }
                }
            }
            .task(id: "\(source.hashValue)::\(colorScheme == .dark ? "dark" : "light")") {
                await loadDiagram()
            }
        }
    }

    private func loadDiagram() async {
        isLoading = true
        errorSummary = nil
        let result = await MermaidRenderer.shared.render(source: source, isDark: colorScheme == .dark)
        switch result {
        case .success(let diagram):
            svg = diagram.svg
            errorSummary = nil
        case .failure(let err):
            svg = nil
            errorSummary = err.localizedDescription
        }
        isLoading = false
    }
}
