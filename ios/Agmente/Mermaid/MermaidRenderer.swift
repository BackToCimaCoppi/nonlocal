import Foundation
import WebKit
import UIKit

struct MermaidRenderedDiagram {
    let svg: String
    let aspectRatio: CGFloat
    let domId: String
    let image: UIImage?
}

enum MermaidRenderError: LocalizedError, Equatable {
    case bundleScriptMissing
    case timeout
    case syntaxError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .bundleScriptMissing:
            return String(localized: "Offline Mermaid script is missing")
        case .timeout:
            return String(localized: "Mermaid rendering timed out (5s)")
        case .syntaxError(let detail):
            return detail.isEmpty ? String(localized: "Mermaid syntax error") : detail
        case .cancelled:
            return String(localized: "Rendering cancelled")
        }
    }
}

/// Shared offline single-WKWebView Mermaid renderer (T10 / DP-6.1 / AC-606~AC-609).
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    static let defaultTimeoutSeconds: TimeInterval = 5.0
    static let maxCacheEntries: Int = 48
    static let didFinishRenderingNotification = Notification.Name("NonlocalMermaidRendererDidFinish")

    /// Strict CSP blocking all external subresources (images, scripts, styles, fonts, XHR).
    static let offlineHTMLSkeleton: String = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:;">
    <style>
      html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
      #stage { display: inline-block; padding: 12px; }
    </style>
    </head>
    <body>
      <div id="stage"></div>
    </body>
    </html>
    """

    struct CacheKey: Hashable {
        let sourceHash: Int
        let sourceLength: Int
        let isDark: Bool
    }

    enum CachedOutcome {
        case ready(MermaidRenderedDiagram)
        case failure(MermaidRenderError)
    }

    private var webView: WKWebView?
    private var isWebViewLoaded = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var renderSequence: UInt64 = 0
    private var cache: [CacheKey: CachedOutcome] = [:]
    private var cacheOrder: [CacheKey] = []
    private var inFlightTasks: [CacheKey: Task<Result<MermaidRenderedDiagram, MermaidRenderError>, Never>] = [:]
    private var queueTail: Task<Void, Never>?

    var timeoutSeconds: TimeInterval = MermaidRenderer.defaultTimeoutSeconds
    /// Exposed for integration testing (AC-606 CSP probe & AC-608 process-termination recovery).
    var activeWebViewForTesting: WKWebView? { webView }
    var currentCacheCount: Int { cache.count }

    private override init() {
        super.init()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearCache()
            }
        }
        #endif
    }

    static func cacheKey(source: String, isDark: Bool) -> CacheKey {
        CacheKey(sourceHash: source.hashValue, sourceLength: source.utf8.count, isDark: isDark)
    }

    static func bundledMermaidScriptURL() -> URL? {
        if let direct = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") {
            return direct
        }
        if let subdir = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Resources") {
            return subdir
        }
        return nil
    }

    func cachedOutcome(source: String, isDark: Bool) -> CachedOutcome? {
        let key = Self.cacheKey(source: source, isDark: isDark)
        guard let existing = cache[key] else { return nil }
        touchCacheKey(key)
        return existing
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    func simulateWebContentTerminationForTesting() {
        if let wv = webView {
            webViewWebContentProcessDidTerminate(wv)
        }
    }

    func render(source: String, isDark: Bool) async -> Result<MermaidRenderedDiagram, MermaidRenderError> {
        if Task.isCancelled {
            return .failure(.cancelled)
        }
        let key = Self.cacheKey(source: source, isDark: isDark)
        if let cached = cachedOutcome(source: source, isDark: isDark) {
            switch cached {
            case .ready(let diagram): return .success(diagram)
            case .failure(let err): return .failure(err)
            }
        }

        if let existing = inFlightTasks[key] {
            return await existing.value
        }

        let previousTail = queueTail
        var finishSlot: (() -> Void)?
        let slotTask = Task<Void, Never> {
            await withCheckedContinuation { cont in
                finishSlot = { cont.resume() }
            }
        }
        queueTail = slotTask

        let task = Task<Result<MermaidRenderedDiagram, MermaidRenderError>, Never> { @MainActor [weak self] in
            defer {
                finishSlot?()
            }
            if let previousTail {
                await previousTail.value
            }
            guard let self else { return .failure(.cancelled) }
            if Task.isCancelled {
                self.inFlightTasks.removeValue(forKey: key)
                return .failure(.cancelled)
            }

            let result = await self.executeSerialRender(source: source, isDark: isDark)
            self.inFlightTasks.removeValue(forKey: key)
            if case .failure(.cancelled) = result {
                return result
            }
            switch result {
            case .success(let diagram):
                self.storeCache(.ready(diagram), for: key)
            case .failure(let err):
                self.storeCache(.failure(err), for: key)
            }
            NotificationCenter.default.post(
                name: Self.didFinishRenderingNotification,
                object: self,
                userInfo: ["sourceHash": key.sourceHash, "isDark": isDark]
            )
            return result
        }

        inFlightTasks[key] = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func executeSerialRender(source: String, isDark: Bool) async -> Result<MermaidRenderedDiagram, MermaidRenderError> {
        guard let wv = await ensureWebViewReady() else {
            return .failure(.bundleScriptMissing)
        }
        if Task.isCancelled {
            return .failure(.cancelled)
        }

        renderSequence &+= 1
        let domId = "mermaid-\(renderSequence)"
        let themeName = isDark ? "dark" : "default"
        let js = """
        return await (async () => {
          const stage = document.getElementById('stage');
          stage.innerHTML = '';
          if (typeof mermaid === 'undefined') {
            return { ok: false, error: 'mermaid runtime unavailable' };
          }
          try {
            mermaid.initialize({
              startOnLoad: false,
              securityLevel: 'strict',
              theme: themeName,
              flowchart: { htmlLabels: true }
            });
            const rendered = await mermaid.render(domId, code);
            stage.innerHTML = rendered.svg;
            const svgEl = stage.querySelector('svg');
            let width = 800;
            let height = 400;
            if (svgEl) {
              const rect = svgEl.getBoundingClientRect();
              if (rect.width > 0 && rect.height > 0) {
                width = rect.width;
                height = rect.height;
              }
            }
            return { ok: true, svg: rendered.svg, width: width, height: height };
          } catch (err) {
            return { ok: false, error: (err && err.message) ? String(err.message) : String(err) };
          }
        })();
        """

        let renderOutcome: Result<(svg: String, width: CGFloat, height: CGFloat), MermaidRenderError> = await withTaskGroup(
            of: Result<(svg: String, width: CGFloat, height: CGFloat), MermaidRenderError>.self
        ) { group in
            group.addTask { @MainActor in
                do {
                    let raw = try await wv.callAsyncJavaScript(
                        js,
                        arguments: ["domId": domId, "code": source, "themeName": themeName],
                        in: nil,
                        contentWorld: .page
                    )
                    guard let dict = raw as? [String: Any] else {
                        return .failure(.syntaxError("Invalid Mermaid renderer response"))
                    }
                    if let ok = dict["ok"] as? Bool, ok, let svg = dict["svg"] as? String, !svg.isEmpty {
                        let w = (dict["width"] as? Double).map { CGFloat($0) } ?? 800
                        let h = (dict["height"] as? Double).map { CGFloat($0) } ?? 400
                        return .success((svg: svg, width: max(1, w), height: max(1, h)))
                    }
                    let errMsg = (dict["error"] as? String) ?? "Syntax error"
                    return .failure(.syntaxError(errMsg))
                } catch {
                    return .failure(.syntaxError(error.localizedDescription))
                }
            }
            let limit = self.timeoutSeconds
            group.addTask {
                let nanos = UInt64(max(0.0005, limit) * 1_000_000_000.0)
                try? await Task.sleep(nanoseconds: nanos)
                return .failure(.timeout)
            }
            let first = await group.next() ?? .failure(.timeout)
            group.cancelAll()
            return first
        }

        switch renderOutcome {
        case .failure(let err):
            if err == .timeout {
                resetWebView()
            }
            return .failure(err)
        case .success(let payload):
            let ratio = max(0.3, min(4.0, payload.width / max(1, payload.height)))
            let snapshotImage = await captureSnapshot(from: wv, width: payload.width, height: payload.height)
            return .success(MermaidRenderedDiagram(
                svg: payload.svg,
                aspectRatio: ratio,
                domId: domId,
                image: snapshotImage
            ))
        }
    }

    private func captureSnapshot(from webView: WKWebView, width: CGFloat, height: CGFloat) async -> UIImage? {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: min(1024, max(200, width + 24)), height: min(768, max(120, height + 24)))
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func ensureWebViewReady() async -> WKWebView? {
        if let existing = webView, isWebViewLoaded {
            return existing
        }
        guard let scriptURL = Self.bundledMermaidScriptURL(),
              let scriptSource = try? String(contentsOf: scriptURL, encoding: .utf8),
              !scriptSource.isEmpty else {
            return nil
        }

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(userScript)

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        wv.navigationDelegate = self
        #if canImport(UIKit)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        #endif
        self.webView = wv
        self.isWebViewLoaded = false

        await withCheckedContinuation { continuation in
            self.loadContinuation = continuation
            wv.loadHTMLString(Self.offlineHTMLSkeleton, baseURL: nil)
        }
        return self.webView
    }

    private func resetWebView() {
        webView?.navigationDelegate = nil
        webView = nil
        isWebViewLoaded = false
    }

    private func storeCache(_ outcome: CachedOutcome, for key: CacheKey) {
        cache[key] = outcome
        touchCacheKey(key)
        while cacheOrder.count > Self.maxCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touchCacheKey(_ key: CacheKey) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
        }
        cacheOrder.append(key)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isWebViewLoaded = true
        let cont = loadContinuation
        loadContinuation = nil
        cont?.resume()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if self.webView === webView {
            resetWebView()
        }
    }
}
