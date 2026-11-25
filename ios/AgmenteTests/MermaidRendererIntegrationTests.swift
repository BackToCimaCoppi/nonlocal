import XCTest
import WebKit
import Network
@testable import Agmente

@MainActor
final class MermaidRendererIntegrationTests: XCTestCase {

    override func tearDown() {
        MermaidRenderer.shared.timeoutSeconds = MermaidRenderer.defaultTimeoutSeconds
        MermaidRenderer.shared.clearCache()
        super.tearDown()
    }

    // MARK: - AC-606 (PP-606-A & PP-606-B): Offline bundle, strict CSP loopback 0-hit probe, dual MIT license

    func testAC606_OfflineBundleStrictCSPLoopbackProbeAndDualLicenses() async throws {
        // 1. Bundle mermaid.min.js exists and source has 0 CDN URLs
        let bundleURL = MermaidRenderer.bundledMermaidScriptURL()
        XCTAssertNotNil(bundleURL, "mermaid.min.js must be bundled in app resources")

        let skeleton = MermaidRenderer.offlineHTMLSkeleton
        XCTAssertTrue(skeleton.contains("default-src 'none'"), "Offline HTML skeleton must declare strict CSP default-src 'none'")

        // Verify MermaidRenderer source has no CDN URLs and sets securityLevel: 'strict' + WKUserScript
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let rendererSource = try String(
            contentsOf: repoRoot.appendingPathComponent("ios/Agmente/Mermaid/MermaidRenderer.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(rendererSource.contains("cdn.jsdelivr.net"))
        XCTAssertFalse(rendererSource.contains("unpkg.com"))
        XCTAssertTrue(rendererSource.contains("WKUserScript"))
        XCTAssertTrue(rendererSource.contains("securityLevel: 'strict'"))

        // 2. PP-606-B: Both root and ios/ THIRD_PARTY_LICENSES.md contain Mermaid MIT license
        let rootLicense = try String(contentsOf: repoRoot.appendingPathComponent("THIRD_PARTY_LICENSES.md"), encoding: .utf8)
        let iosLicense = try String(contentsOf: repoRoot.appendingPathComponent("ios/THIRD_PARTY_LICENSES.md"), encoding: .utf8)
        XCTAssertTrue(rootLicense.lowercased().contains("mermaid") && rootLicense.contains("MIT"), "Root THIRD_PARTY_LICENSES.md must contain Mermaid MIT")
        XCTAssertTrue(iosLicense.lowercased().contains("mermaid") && iosLicense.contains("MIT"), "ios/THIRD_PARTY_LICENSES.md must contain Mermaid MIT")

        // 3. PP-606-A: Warm up real offscreen WKWebView, spin up real loopback TCP listener,
        // inject <img src="http://127.0.0.1:<port>/probe.png"> directly into offscreen container,
        // and verify 0 HTTP connections hit the loopback probe (CSP blocks external subresources).
        let warmup = await MermaidRenderer.shared.render(source: "graph TD\n  Start --> End", isDark: false)
        switch warmup {
        case .success(let diagram):
            XCTAssertTrue(diagram.svg.contains("<svg"), "Offline mermaid.min.js must render valid <svg>")
        case .failure(let err):
            XCTFail("Warmup offline mermaid render failed: \(err)")
        }

        let webView = try XCTUnwrap(MermaidRenderer.shared.activeWebViewForTesting)
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.mermaid.csp.probe")
        var hitCount = 0
        let hitLock = NSLock()
        let readyExp = expectation(description: "loopback listener ready")

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                readyExp.fulfill()
            }
        }
        listener.newConnectionHandler = { conn in
            hitLock.lock()
            hitCount += 1
            hitLock.unlock()
            conn.cancel()
        }
        listener.start(queue: queue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        defer { listener.cancel() }

        let port = try XCTUnwrap(listener.port?.rawValue)
        let probeJS = """
        return await new Promise(function(resolve) {
            var img = document.createElement('img');
            img.onerror = function() { resolve('blocked_or_error'); };
            img.onload = function() { resolve('loaded'); };
            img.src = 'http://127.0.0.1:\(port)/probe.png';
            document.body.appendChild(img);
            setTimeout(function() { resolve('timeout_blocked'); }, 800);
        });
        """
        let probeResult = try await webView.callAsyncJavaScript(probeJS, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertNotEqual(probeResult, "loaded", "CSP must block loopback image subresource")

        // Give any stray socket attempt 250ms to arrive
        try await Task.sleep(nanoseconds: 250_000_000)
        hitLock.lock()
        let observedHits = hitCount
        hitLock.unlock()
        XCTAssertEqual(observedHits, 0, "PP-606-A: Loopback probe must receive 0 HTTP requests under strict CSP")
    }

    // MARK: - AC-607: Concurrent serialization, unique monotonic DOM IDs, cache hit, cancellation, LRU 48

    func testAC607_ConcurrencyUniqueIDsCacheHitCancelAndLRU48() async {
        MermaidRenderer.shared.clearCache()

        let src1 = "graph TD\n  A1 --> B1"
        let src2 = "graph TD\n  A2 --> B2"
        let src3 = "graph TD\n  A3 --> B3"

        // Concurrent submission of 3 distinct + 1 duplicate
        async let r1 = MermaidRenderer.shared.render(source: src1, isDark: false)
        async let r2 = MermaidRenderer.shared.render(source: src2, isDark: false)
        async let r3 = MermaidRenderer.shared.render(source: src3, isDark: false)
        async let r1Dup = MermaidRenderer.shared.render(source: src1, isDark: false)

        let results = await [r1, r2, r3, r1Dup]
        guard case .success(let d1) = results[0],
              case .success(let d2) = results[1],
              case .success(let d3) = results[2],
              case .success(let d1Dup) = results[3] else {
            XCTFail("All 4 concurrent renders must succeed")
            return
        }

        XCTAssertEqual(Set([d1.domId, d2.domId, d3.domId]).count, 3, "3 distinct diagrams must get 3 unique DOM IDs")
        XCTAssertEqual(d1.domId, d1Dup.domId, "Duplicate diagram must hit cache / in-flight dedup with identical DOM ID")
        XCTAssertTrue(d1.svg.contains("A1"))
        XCTAssertTrue(d2.svg.contains("A2"))
        XCTAssertTrue(d3.svg.contains("A3"))

        // Enqueue a task behind an active render and cancel it before dequeue (strict assertion, zero silent skip)
        let blockerSource = "graph TD\n  BLOCKER_\(UUID().uuidString) --> B"
        let cancelledSource = "graph TD\n  CANCEL_ME_\(UUID().uuidString) --> NEVER"
        let blockerTask = Task {
            await MermaidRenderer.shared.render(source: blockerSource, isDark: false)
        }
        let cancelTask = Task {
            await MermaidRenderer.shared.render(source: cancelledSource, isDark: false)
        }
        cancelTask.cancel()
        let cancelOutcome = await cancelTask.value
        _ = await blockerTask.value
        switch cancelOutcome {
        case .failure(let err):
            XCTAssertEqual(err, .cancelled, "Cancelled task must fail with .cancelled")
        case .success:
            XCTFail("Cancelled task must not silently succeed")
        }

        // LRU 48 eviction test
        MermaidRenderer.shared.clearCache()
        let firstSrc = "graph TD\n  LRU_0 --> END"
        for i in 0..<49 {
            let src = "graph TD\n  LRU_\(i) --> END"
            let res = await MermaidRenderer.shared.render(source: src, isDark: false)
            if case .failure(let err) = res {
                XCTFail("LRU diagram \(i) failed: \(err)")
                return
            }
        }
        XCTAssertLessThanOrEqual(MermaidRenderer.shared.currentCacheCount, MermaidRenderer.maxCacheEntries)
        XCTAssertEqual(MermaidRenderer.shared.currentCacheCount, 48)
        XCTAssertNil(MermaidRenderer.shared.cachedOutcome(source: firstSrc, isDark: false), "Oldest entry LRU_0 must be evicted after 49 inserts")
    }

    // MARK: - AC-608: WebContent process termination self-heal, 5s timeout constant, syntax error & timeout

    func testAC608_CrashRecoveryTimeoutConstantAndSyntaxFailure() async {
        XCTAssertEqual(MermaidRenderer.defaultTimeoutSeconds, 5.0, "Default timeout constant must be 5.0s")

        // Warm up, then simulate WebContent process termination
        let initial = await MermaidRenderer.shared.render(source: "graph TD\n  Pre --> Crash", isDark: false)
        if case .failure(let err) = initial {
            XCTFail("Initial render failed: \(err)")
            return
        }

        if let wv = MermaidRenderer.shared.activeWebViewForTesting {
            MermaidRenderer.shared.webViewWebContentProcessDidTerminate(wv)
        }

        let afterCrash = await MermaidRenderer.shared.render(source: "graph TD\n  Post --> Recovery", isDark: false)
        switch afterCrash {
        case .success(let diagram):
            XCTAssertTrue(diagram.svg.contains("<svg"))
            XCTAssertNotNil(diagram.image)
        case .failure(let err):
            XCTFail("Renderer must self-heal after WebContent termination, got: \(err)")
        }

        // Invalid syntax must return explicit .failure(.syntaxError)
        let bad = await MermaidRenderer.shared.render(source: "graph TD\n  A ---> === INVALID ???", isDark: false)
        switch bad {
        case .success:
            XCTFail("Invalid Mermaid syntax must fail, never return blank pseudo-success")
        case .failure(let err):
            if case .syntaxError = err {
                // expected
            } else {
                XCTFail("Expected .syntaxError, got \(err)")
            }
        }

        // Timeout branch must return explicit .failure(.timeout)
        MermaidRenderer.shared.timeoutSeconds = 0.0001
        let timedOut = await MermaidRenderer.shared.render(
            source: "graph TD\n  TIMEOUT_\(UUID().uuidString) --> Z",
            isDark: false
        )
        MermaidRenderer.shared.timeoutSeconds = MermaidRenderer.defaultTimeoutSeconds
        switch timedOut {
        case .success:
            XCTFail("0.0001s timeout must fail with .timeout")
        case .failure(let err):
            XCTAssertEqual(err, .timeout, "Expected .timeout error")
        }
    }

    // MARK: - AC-609 (PP-609-A): Real `.md` WKWebView with allowsContentJavaScript==false, 2 normal + 1 broken mermaid + XSS

    func testAC609_MarkdownPreviewWebViewZeroJSAndSharedMermaid() async throws {
        let md = """
        # 测试文档

        <script>window.__xss = 1;</script>

        ```mermaid
        graph TD
          X --> Y
        ```

        ```mermaid
        graph TD
          X --> Y
        ```

        ```mermaid
        graph TD
          A ---> === INVALID ???
        ```
        """

        // Pre-render via shared MermaidRenderer (same path as RemoteFilePreviewView)
        var rendered: [Int: Result<String, Error>] = [:]
        var idxCounter = 0
        _ = MarkdownToHTMLConverter.convertBody(markdown: md) { _, _ in
            idxCounter += 1
            return ""
        }
        let sources = ["graph TD\n  X --> Y", "graph TD\n  X --> Y", "graph TD\n  A ---> === INVALID ???"]
        for (idx, src) in sources.enumerated() {
            let res = await MermaidRenderer.shared.render(source: src, isDark: false)
            switch res {
            case .success(let d): rendered[idx] = .success(d.svg)
            case .failure(let e): rendered[idx] = .failure(e)
            }
        }

        let html = MarkdownToHTMLConverter.convertToHTMLDocument(
            markdown: md,
            isDark: false,
            mermaidRenderer: { source, idx in
                switch rendered[idx] {
                case .success(let svg):
                    let deduped = MarkdownToHTMLConverter.deduplicateSVGIds(svg, prefix: "mdm\(idx)")
                    return "<div class=\"mermaid-diagram\">\(deduped)</div>"
                case .failure(let err):
                    return "<div class=\"markdown-prose\"><div class=\"mermaid-error-banner\">Mermaid 渲染失败：\(MarkdownToHTMLConverter.escapeHTML(err.localizedDescription))</div><pre><code class=\"language-mermaid\">\(MarkdownToHTMLConverter.escapeHTML(source))</code></pre></div>"
                case .none:
                    return ""
                }
            }
        )

        // Load into real WKWebView with allowsContentJavaScript = false (PP-609-A)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        XCTAssertFalse(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)

        final class LoadDelegate: NSObject, WKNavigationDelegate {
            let exp: XCTestExpectation
            init(exp: XCTestExpectation) { self.exp = exp }
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                exp.fulfill()
            }
        }
        let exp = expectation(description: "md webview finish")
        let delegate = LoadDelegate(exp: exp)
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [exp], timeout: 5.0)

        // Evaluate in page context (evaluateJavaScript runs from host even when content JS is disabled)
        let xssVal = try await webView.evaluateJavaScript("typeof window.__xss") as? String
        XCTAssertEqual(xssVal, "undefined", "PP-609-A: <script>window.__xss=1</script> must NOT execute when allowsContentJavaScript==false")

        let svgCount = try await webView.evaluateJavaScript("document.querySelectorAll('.mermaid-diagram svg').length") as? Int
        XCTAssertEqual(svgCount, 2, "Both valid Mermaid blocks must render as inline <svg>")

        let dupIdCount = try await webView.evaluateJavaScript("""
            (function() {
                var els = document.querySelectorAll('[id]');
                var seen = {};
                var dups = 0;
                for (var i = 0; i < els.length; i++) {
                    var id = els[i].id;
                    if (seen[id]) dups++;
                    seen[id] = true;
                }
                return dups;
            })();
        """) as? Int
        XCTAssertEqual(dupIdCount, 0, "Zero duplicate DOM IDs across 2 identical Mermaid SVGs in .md")

        let errorBannerCount = try await webView.evaluateJavaScript("document.querySelectorAll('.mermaid-error-banner').length") as? Int
        XCTAssertEqual(errorBannerCount, 1, "Broken Mermaid block must render local error banner + escaped source")
    }
}
