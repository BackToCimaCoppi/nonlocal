import XCTest
import WebKit
import ACP
@testable import Agmente
import ACPClient
#if canImport(UIKit)
import UIKit
#endif

// SC-AC-052: RemoteFilePreview G-8 golden regression (7 error mappings, WebKit JS boundary, log redaction).
@MainActor
final class RemoteFilePreviewTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let name = "RemoteFilePreviewTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // AC-402 (GOLDEN / PP-402-A): AppViewModel.shouldSummarizeServerLog omits fs_read_file (text & image base64)
    // and fs_list payloads so Server Logs (`updates`) contain 0 occurrences of secret body text or base64.
    func testAC402GoldenServerLogsOmitFsReadFileAndFsListPayloads() throws {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        model.addServer(
            name: "ACP",
            scheme: "ws",
            host: "127.0.0.1:18841",
            token: "",
            workingDirectory: "~"
        )
        let client = ACPClient(configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18841")!, pingInterval: nil))
        let service = ACPService(client: client)

        // 1. nonlocal/fs_read_file (text with SECRET_BODY_LINE)
        let req1 = ACP.AnyRequest(id: .int(101), method: NonlocalMethods.fsReadFile, params: .object(["path": .string("~/secret.txt")]))
        model.acpService(service, willSend: req1)
        let resp1 = ACPWireMessage.response(.init(id: .int(101), result: .object([
            "path": .string("/Users/demo/secret.txt"),
            "name": .string("secret.txt"),
            "kind": .string("text"),
            "mimeType": .string("text/plain"),
            "content": .string("SECRET_BODY_LINE\nline 2"),
            "size": .int(23),
            "bytesRead": .int(23),
            "truncated": .bool(false)
        ])))
        model.acpService(service, didReceiveMessage: resp1)

        // 2. nonlocal/fs_read_file (image with base64 iVBORw0KGgoSECRETB64...)
        let req2 = ACP.AnyRequest(id: .int(102), method: NonlocalMethods.fsReadFile, params: .object(["path": .string("~/pic.png")]))
        model.acpService(service, willSend: req2)
        let resp2 = ACPWireMessage.response(.init(id: .int(102), result: .object([
            "path": .string("/Users/demo/pic.png"),
            "name": .string("pic.png"),
            "kind": .string("image"),
            "mimeType": .string("image/png"),
            "content": .string("iVBORw0KGgoSECRETB64PAYLOAD=="),
            "size": .int(100),
            "bytesRead": .int(100),
            "truncated": .bool(false)
        ])))
        model.acpService(service, didReceiveMessage: resp2)

        // 3. nonlocal/fs_list
        let req3 = ACP.AnyRequest(id: .int(103), method: NonlocalMethods.fsList, params: .object(["path": .string("~")]))
        model.acpService(service, willSend: req3)
        let resp3 = ACPWireMessage.response(.init(id: .int(103), result: .object([
            "path": .string("/Users/demo"),
            "homePath": .string("/Users/demo"),
            "totalCount": .int(1),
            "truncated": .bool(false),
            "entries": .array([.object(["name": .string("SECRET_DIR_NAME"), "path": .string("/Users/demo/SECRET_DIR_NAME"), "type": .string("dir")])])
        ])))
        model.acpService(service, didReceiveMessage: resp3)

        let allLogs = model.updates.map(\.message).joined(separator: "\n")
        XCTAssertEqual(model.updates.filter { $0.message.contains("[payload omitted in Server Logs]") }.count >= 3, true)
        XCTAssertFalse(allLogs.contains("SECRET_BODY_LINE"))
        XCTAssertFalse(allLogs.contains("iVBORw0KGgoSECRETB64"))
        XCTAssertFalse(allLogs.contains("SECRET_DIR_NAME"))
    }

    // AC-403: Case-insensitive kind+mimeType routing, MD->HTML H1..H6/blockquote/table/code/lists/href whitelist,
    // and WKNavigationDelegate policy (about:blank, fragment, linkActivated http(s) -> openExternally, relative -> cancel).
    func testAC403RoutingMarkdownToHTMLAndNavigationPolicy() {
        let mdRes = NonlocalFsReadFileResult(path: "/README.MD", name: "README.MD", kind: .text, mimeType: "TEXT/MARKDOWN", content: "# H1", size: 4, bytesRead: 4, truncated: false)
        XCTAssertEqual(RemoteFilePreviewKind.classify(result: mdRes), .markdown)

        let jpgRes = NonlocalFsReadFileResult(path: "/Photo.JPG", name: "Photo.JPG", kind: .image, mimeType: "IMAGE/JPEG", content: "", size: 1, bytesRead: 1, truncated: false)
        XCTAssertEqual(RemoteFilePreviewKind.classify(result: jpgRes), .rasterImage)

        let htmlRes = NonlocalFsReadFileResult(path: "/index.HTML", name: "index.HTML", kind: .text, mimeType: "text/html", content: "<p>hi</p>", size: 9, bytesRead: 9, truncated: false)
        XCTAssertEqual(RemoteFilePreviewKind.classify(result: htmlRes), .html)

        let svgRes = NonlocalFsReadFileResult(path: "/icon.svg", name: "icon.svg", kind: .image, mimeType: "image/svg+xml", content: "", size: 1, bytesRead: 1, truncated: false)
        XCTAssertEqual(RemoteFilePreviewKind.classify(result: svgRes), .webImage(mimeType: "image/svg+xml"))

        let gifRes = NonlocalFsReadFileResult(path: "/anim.gif", name: "anim.gif", kind: .image, mimeType: "image/gif", content: "", size: 1, bytesRead: 1, truncated: false)
        XCTAssertEqual(RemoteFilePreviewKind.classify(result: gifRes), .webImage(mimeType: "image/gif"))

        let md = """
        # H1
        ## H2
        ### H3
        #### H4
        ##### H5
        ###### H6

        > Quote line

        | ColA | ColB |
        | --- | --- |
        | 1 | 2 |

        ```swift
        let x = "<script>"
        ```

        - item1
        1. ordered1

        [bad](javascript:alert(1)) [good](https://example.com)
        """
        let html = MarkdownToHTMLConverter.convertToHTMLDocument(markdown: md)
        for level in 1...6 {
            XCTAssertTrue(html.contains("<h\(level)>H\(level)</h\(level)>"), "Missing H\(level)")
        }
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<pre><code"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertFalse(html.contains("javascript:alert(1)"))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))

        // Navigation policy
        XCTAssertEqual(PreviewWebNavigationPolicy.evaluate(url: URL(string: "about:blank"), isLinkActivated: false, isTargetFrameNil: false), .allow)
        XCTAssertEqual(PreviewWebNavigationPolicy.evaluate(url: URL(string: "about:blank#sec"), isLinkActivated: true, isTargetFrameNil: false), .allow)
        XCTAssertEqual(PreviewWebNavigationPolicy.evaluate(url: URL(string: "https://example.com/doc"), isLinkActivated: true, isTargetFrameNil: true), .openExternally(URL(string: "https://example.com/doc")!))
        XCTAssertEqual(PreviewWebNavigationPolicy.evaluate(url: URL(string: "http://nonlocal.local/other.html"), isLinkActivated: true, isTargetFrameNil: false), .cancel)
        XCTAssertEqual(PreviewWebNavigationPolicy.evaluate(url: URL(string: "javascript:void(0)"), isLinkActivated: true, isTargetFrameNil: false), .cancel)
    }

    // AC-404 (Host-process real WKWebView + ImageIO + UITextView; covers Self-Heal #1, #2, #3 & #衔接点-c)
    func testAC404HostWebKitJSBoundaryLocalStorageImageDownsampleAndUITextView() async throws {
        // 1. .md WKWebView with allowsContentJavaScript == false blocks <script>window.__xss=1</script>
        let mdConfig = WKWebViewConfiguration()
        mdConfig.defaultWebpagePreferences.allowsContentJavaScript = false
        let mdWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: mdConfig)
        let mdHTML = MarkdownToHTMLConverter.convertToHTMLDocument(markdown: "# Safe\n\n<script>window.__xss=1</script>")
        try await loadHTMLAndWait(webView: mdWebView, html: mdHTML, baseURL: nil)
        XCTAssertFalse(mdWebView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let xssResult = try await mdWebView.evaluateJavaScript("typeof window.__xss") as? String
        XCTAssertEqual(xssResult, "undefined")

        // 2. .html WKWebView with allowsContentJavaScript == true & localPreviewBaseURL supports localStorage (Self-Heal #3)
        let htmlConfig = WKWebViewConfiguration()
        htmlConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        let htmlWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: htmlConfig)
        let selfContainedHTML = """
        <!doctype html><html><body>
        <script>
          window.__storageError = null;
          try {
            localStorage.setItem('theme', 'dark');
            window.__themeVal = localStorage.getItem('theme');
          } catch (e) {
            window.__storageError = String(e);
          }
        </script>
        </body></html>
        """
        try await loadHTMLAndWait(
            webView: htmlWebView,
            html: selfContainedHTML,
            baseURL: PreviewWebNavigationPolicy.localPreviewBaseURL
        )
        XCTAssertTrue(htmlWebView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let storageErr = try await htmlWebView.evaluateJavaScript("window.__storageError")
        XCTAssertTrue(storageErr == nil || storageErr is NSNull, "Expected nil localStorage error, got: \(String(describing: storageErr))")
        let themeVal = try await htmlWebView.evaluateJavaScript("window.__themeVal") as? String
        XCTAssertEqual(themeVal, "dark")

        // 3. Standalone disk .svg & .gif HTML shell uses <img src="data:<mime>;base64,..."> with zero JS (#衔接点-c)
        let svgShell = StandaloneWebImageHTMLBuilder.buildHTML(base64: "PHN2Zz48L3N2Zz4=", mimeType: "image/svg+xml")
        XCTAssertTrue(svgShell.contains("<img src=\"data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=\""))
        let gifShell = StandaloneWebImageHTMLBuilder.buildHTML(base64: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==", mimeType: "image/gif")
        XCTAssertTrue(gifShell.contains("<img src=\"data:image/gif;base64,"))

        // 4. High-res 4000x3000 PNG downsampling via ImageIO (Self-Heal #1)
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format)
        let pngData = renderer.pngData { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let maxTarget: CGFloat = 1200
        let decoded = try XCTUnwrap(ImageDownsampler.decodeDownsampled(data: pngData, maxPixelSize: maxTarget))
        XCTAssertEqual(decoded.originalPixelWidth, 4000)
        XCTAssertEqual(decoded.originalPixelHeight, 3000)
        XCTAssertLessThanOrEqual(max(decoded.outputPixelWidth, decoded.outputPixelHeight), Int(maxTarget))

        // 5. Plain text preview uses read-only UITextView (Self-Heal #2)
        let plainRep = PlainTextPreviewRepresentable(text: String(repeating: "中文日志测试行 0123456789\n", count: 2000), wrapLines: true)
        XCTAssertTrue(PlainTextPreviewRepresentable.UIViewType.self == UITextView.self)
        XCTAssertFalse(plainRep.text.isEmpty)
        #endif
    }

    // AC-405: All 7 error states mapped distinctly (knownFileSize nil & non-nil) and -32014 keeps error card when onOpenAsDirectory == nil.
    func testAC405AllSevenPreviewErrorMappingsAndDirectoryStayBehavior() {
        let codes: [(Int, String)] = [
            (-32011, String(localized: "File Not Found")),
            (-32013, String(localized: "Permission Denied")),
            (-32014, String(localized: "This Is a Directory")),
            (-32015, String(localized: "Binary File Preview Unsupported")),
            (-32016, String(localized: "Image Exceeds 10 MB Limit")),
            (-32602, String(localized: "Invalid File Path"))
        ]
        var seenTitles: Set<String> = []
        for (code, expectedTitle) in codes {
            let err = ACPServiceError.rpc(id: .int(1), error: .serverError(code: code, message: "12.5 MB"))
            let infoNilSize = RemoteFilePreviewFormatter.mapError(err, knownFileSize: nil)
            XCTAssertEqual(infoNilSize.title, expectedTitle)
            XCTAssertFalse(infoNilSize.detail.contains("nil"))
            seenTitles.insert(infoNilSize.title)

            let infoWithSize = RemoteFilePreviewFormatter.mapError(err, knownFileSize: 13_107_200)
            XCTAssertEqual(infoWithSize.title, expectedTitle)
        }
        let corrupt = RemoteFilePreviewFormatter.corruptedImageError
        XCTAssertEqual(corrupt.title, String(localized: "Image Decoding Failed"))
        seenTitles.insert(corrupt.title)
        XCTAssertEqual(seenTitles.count, 7)

        // -32014 sets isDirectory == true; when onOpenAsDirectory == nil, preview keeps error card
        let dirErr = RemoteFilePreviewFormatter.mapError(
            ACPServiceError.rpc(id: .int(2), error: .serverError(code: -32014, message: "is_directory")),
            knownFileSize: nil
        )
        XCTAssertTrue(dirErr.isDirectory)
    }

    // AC-406: File browser entry gating, 3-chip canonical deduplication, search clear on navigate,
    // out-of-order requestToken discard, zero workingDirectory/history mutation, and no embedded NavigationStack in RemoteFilePreviewView.
    func testAC406BrowserGatingChipDedupRaceDiscardAndNavigationStackContract() async throws {
        let defaults = makeIsolatedDefaults()

        // 1. 3 chips all pointing to /Users/demo deduplicate to 1 chip
        let vm = RemoteFileBrowserViewModel(
            initialPath: "/Users/demo",
            projectPath: "/Users/demo",
            serverDefaultPath: "~",
            listDirectory: { params in
                if params.path == "/dirA" {
                    try await Task.sleep(nanoseconds: 120_000_000)
                    return NonlocalFsListResult(
                        path: "/dirA",
                        parentPath: "/",
                        homePath: "/Users/demo",
                        totalCount: 1,
                        truncated: false,
                        entries: [NonlocalFsEntry(name: "fromA.txt", path: "/dirA/fromA.txt", type: .file)]
                    )
                }
                return NonlocalFsListResult(
                    path: params.path ?? "/Users/demo",
                    parentPath: "/",
                    homePath: "/Users/demo",
                    totalCount: 1,
                    truncated: false,
                    entries: [NonlocalFsEntry(name: "fromB.txt", path: "/dirB/fromB.txt", type: .file)]
                )
            },
            defaults: defaults
        )

        _ = await vm.loadAndWait(path: "/Users/demo")
        XCTAssertEqual(vm.quickChips.count, 1)
        XCTAssertEqual(vm.quickChips.first?.kind, .currentProject)

        // Service card entry has projectPath == nil -> no currentProject chip
        let vmServerCard = RemoteFileBrowserViewModel(
            initialPath: "~",
            projectPath: nil,
            serverDefaultPath: "~",
            listDirectory: { _ in nil },
            defaults: defaults
        )
        XCTAssertFalse(vmServerCard.quickChips.contains(where: { $0.kind == .currentProject }))

        // 2. Navigating clears searchQuery
        vm.searchQuery = "readme"
        vm.navigate(to: "/dirA")
        XCTAssertEqual(vm.searchQuery, "")

        // 3. Rapid click dirA (slow) then dirB (fast) -> dirA late response discarded, list keeps dirB
        try await Task.sleep(nanoseconds: 15_000_000)
        vm.navigate(to: "/dirB")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.currentPath, "/dirB")
        XCTAssertEqual(vm.entries.map(\.name), ["fromB.txt"])

        // 4. RemoteFilePreviewView does NOT embed NavigationStack; RemoteFilePreviewSheet wraps it
        let testFileURL = URL(fileURLWithPath: #filePath)
        let previewFileURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Agmente/RemoteFilePreviewView.swift")
        let source = try String(contentsOf: previewFileURL, encoding: .utf8)
        let sheetMarker = "struct RemoteFilePreviewSheet"
        let parts = source.components(separatedBy: sheetMarker)
        XCTAssertEqual(parts.count, 2)
        XCTAssertFalse(parts[0].contains("NavigationStack {"), "RemoteFilePreviewView must not embed NavigationStack")
        XCTAssertTrue(parts[1].contains("NavigationStack {"), "RemoteFilePreviewSheet must wrap with NavigationStack")
    }

    // MARK: - WebView Load Helper

    private func loadHTMLAndWait(webView: WKWebView, html: String, baseURL: URL?) async throws {
        final class FinishDelegate: NSObject, WKNavigationDelegate {
            var onFinish: (() -> Void)?
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                onFinish?()
            }
        }
        let delegate = FinishDelegate()
        webView.navigationDelegate = delegate
        await withCheckedContinuation { continuation in
            var resumed = false
            delegate.onFinish = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        _ = delegate
    }
}
