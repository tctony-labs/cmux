import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
final class MarkdownMermaidZoomTests {
    @Test
    func renderedMermaidDiagramScalesWithViewerZoom() async throws {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-mermaid-zoom-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        let configuration = WKWebViewConfiguration()
        let mermaidHandler = MarkdownMermaidStubHandler()
        configuration.userContentController.add(mermaidHandler, name: "cmuxLib")
        let webView = MarkdownWebView(frame: frame, configuration: configuration)
        mermaidHandler.webView = webView
        let coordinator = MarkdownWebRenderer.Coordinator()
        coordinator.webView = webView
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            coordinator.webView = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
            window.close()
        }

        let loadDelegate = MermaidZoomShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(MarkdownViewerAssets.shared.shellHTML(isDark: true), in: webView, baseURL: markdownURL)

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize)
        try await renderMarkdown(
            """
            Prose before the diagram.

            ```mermaid
            flowchart LR
              host[Host process] --> backend[Backend]
              backend --> worker[Worker]
            ```
            """,
            in: webView
        )

        let baseline = try await waitForMermaidSnapshot(in: webView)
        let baselineWidth = try #require(baseline["width"])
        let baselineProseHeight = try #require(baseline["proseHeight"])
        #expect(abs((baseline["zoom"] ?? -1) - 1) <= 0.001)
        #expect(abs(baselineWidth - 240) <= 2)

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize * 2)
        let zoomed = try await waitForMermaidSnapshot(in: webView, expectedZoom: 2)
        let zoomedWidth = try #require(zoomed["width"])
        let zoomedProseHeight = try #require(zoomed["proseHeight"])
        #expect(zoomedWidth > baselineWidth * 1.8)
        #expect(abs((zoomedWidth / baselineWidth) - (zoomedProseHeight / baselineProseHeight)) <= 0.25)
        let exported = try await exportedMermaidSnapshot(in: webView)
        #expect((exported["width"] ?? "missing") == "")
        #expect((exported["height"] ?? "missing") == "")
        #expect(exported["maxWidth"] == "240px")
        #expect(exported["hasCmuxData"] == "0")

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize)
        try await renderMarkdown(
            """
            ```mermaid
            flowchart LR
              wideDiagram[Very wide diagram] --> wider[Still fits at one hundred percent]
            ```
            """,
            in: webView
        )
        let fitted = try await waitForMermaidSnapshot(in: webView)
        let fittedWidth = try #require(fitted["width"])
        let fittedContainerWidth = try #require(fitted["containerWidth"])
        #expect(fittedWidth > baselineWidth * 1.8)
        #expect(fittedWidth <= fittedContainerWidth + 2)

        coordinator.setFontSize(MarkdownFontSizeSettings.defaultPointSize * 2)
        let fittedZoomed = try await waitForMermaidSnapshot(in: webView, expectedZoom: 2)
        let fittedZoomedWidth = try #require(fittedZoomed["width"])
        #expect(fittedZoomedWidth > fittedWidth * 1.8)
        #expect((try #require(fittedZoomed["leftOffset"])) >= -1)

        let widerFrame = NSRect(x: 0, y: 0, width: 960, height: 480)
        window.setFrame(widerFrame, display: true)
        webView.frame = widerFrame
        _ = try await webView.evaluateJavaScript("window.__cmuxSetMarkdownZoom(2);")
        let widened = try await waitForMermaidSnapshot(
            in: webView,
            expectedZoom: 2,
            minimumWidth: fittedZoomedWidth * 1.1
        )
        let widenedWidth = try #require(widened["width"])
        #expect(widenedWidth > fittedZoomedWidth * 1.1)
    }

    private func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

    private func waitForMermaidSnapshot(
        in webView: WKWebView,
        expectedZoom: Double? = nil,
        minimumWidth: Double? = nil
    ) async throws -> [String: Double] {
        let deadline = Date().addingTimeInterval(3)
        var lastSnapshot: [String: Double]?
        while Date() < deadline {
            if let snapshot = try await mermaidSnapshot(in: webView) {
                lastSnapshot = snapshot
                let zoomMatches = expectedZoom.map { abs((snapshot["zoom"] ?? -1) - $0) <= 0.001 } ?? true
                let widthMatches = minimumWidth.map { (snapshot["width"] ?? 0) >= $0 } ?? ((snapshot["width"] ?? 0) > 0)
                if zoomMatches && widthMatches {
                    return snapshot
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MermaidSnapshotTimeout(lastSnapshot: lastSnapshot)
    }

    private func mermaidSnapshot(in webView: WKWebView) async throws -> [String: Double]? {
        let result = try await webView.evaluateJavaScript(
            """
            (function() {
              var svg = document.querySelector('.cmux-mermaid svg');
              if (!svg) { return null; }
              var rect = svg.getBoundingClientRect();
              var container = svg.closest('.cmux-mermaid');
              var containerRect = container ? container.getBoundingClientRect() : null;
              var prose = document.querySelector('.markdown-body p');
              var proseRect = prose ? prose.getBoundingClientRect() : null;
              var zoom = Number(svg.getAttribute('data-cmux-mermaid-zoom') || '1');
              return {
                width: rect.width || 0,
                containerWidth: containerRect ? (containerRect.width || 0) : 0,
                leftOffset: containerRect ? ((rect.left || 0) - (containerRect.left || 0)) : 0,
                proseHeight: proseRect ? (proseRect.height || 0) : 0,
                zoom: Number.isFinite(zoom) ? zoom : 1
              };
            })();
            """
        )
        guard let raw = result as? [String: Any] else { return nil }
        var snapshot: [String: Double] = [:]
        for (key, value) in raw {
            if let number = value as? NSNumber { snapshot[key] = number.doubleValue }
        }
        return snapshot
    }

    private func exportedMermaidSnapshot(in webView: WKWebView) async throws -> [String: String] {
        let result = try await webView.evaluateJavaScript(
            """
            (function() {
              var wrapper = document.createElement('div');
              wrapper.innerHTML = window.__cmuxRenderedHTML();
              var svg = wrapper.querySelector('.cmux-mermaid svg');
              if (!svg) { return {}; }
              return {
                width: svg.style.width || '',
                height: svg.style.height || '',
                maxWidth: svg.style.maxWidth || '',
                hasCmuxData: Array.prototype.some.call(svg.attributes || [], function(attr) {
                  return String(attr.name || '').indexOf('data-cmux-') === 0;
                }) ? '1' : '0'
              };
            })();
            """
        )
        guard let raw = result as? [String: Any] else { return [:] }
        return raw.reduce(into: [String: String]()) { output, item in
            output[item.key] = item.value as? String
        }
    }
}

private final class MermaidZoomShellLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}

private struct MermaidSnapshotTimeout: Error, CustomStringConvertible {
    let lastSnapshot: [String: Double]?

    var description: String {
        "Timed out waiting for Mermaid snapshot: \(String(describing: lastSnapshot))"
    }
}

@MainActor
private final class MarkdownMermaidStubHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "cmuxLib",
              let body = message.body as? [String: Any],
              body["lib"] as? String == "mermaid" else { return }
        webView?.evaluateJavaScript(
            """
            window.mermaid = {
              initialize: function() {},
              render: function(id, src) {
                var isWide = String(src || '').indexOf('wideDiagram') !== -1;
                var width = isWide ? 1200 : 240;
                var height = isWide ? 600 : 120;
                return Promise.resolve({
                  svg: '<svg data-stub-mermaid="1" width="100%" style="max-width:' + width + 'px;" viewBox="0 0 ' + width + ' ' + height + '" xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="' + width + '" height="' + height + '" fill="#d73a49"></rect><text x="20" y="65" font-size="18" fill="#ffffff">Mermaid label</text></svg>'
                });
              }
            };
            if (window.__cmuxLibLoaded) { window.__cmuxLibLoaded('mermaid'); }
            """,
            completionHandler: nil
        )
    }
}

@MainActor
@Suite
struct MarkdownMathTests {
    @Test(arguments: [
        #"$\frac{x_1}{2}$"#,
        #"\(\frac{x_1}{2}\)"#,
        #"$$\frac{x_1}{2}$$"#,
        #"\[\frac{x_1}{2}\]"#
    ])
    func commonDelimitersRender(_ markdown: String) async throws {
        let renderer = MarkdownMathTestRenderer()
        defer { renderer.close() }
        try await renderer.load(markdown)
        #expect(try await renderer.count(".cmux-math .katex") == 1)
        #expect(try await renderer.count(".cmux-math-error") == 0)
        #expect(try await renderer.count(".katex .mfrac") == 1)
        let display = markdown.hasPrefix("$$") || markdown.hasPrefix(#"\["#)
        #expect(try await renderer.count(".katex-display") == (display ? 1 : 0))

        let fontsLoaded = try await renderer.webView.callAsyncJavaScript(
            """
            await document.fonts.ready;
            return document.fonts.check('16px KaTeX_Main')
              && document.fonts.check('16px KaTeX_Math');
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool
        #expect(fontsLoaded == true)
    }

    @Test
    func rmsnormBlocksAndMarkdownStructureRender() async throws {
        let renderer = MarkdownMathTestRenderer()
        defer { renderer.close() }
        try await renderer.load(#"""
        # RMSNorm

        $$
        x = [x_1, \ldots, x_D]
        $$

        $$
        m = \frac{1}{D}\sum_{i=1}^{D}x_i^2
        $$

        \[
        r = \sqrt{m + \epsilon}
        \]

        $$
        \hat{x}_i = \frac{x_i}{r}
        $$

        $$
        \frac{1}{D}\sum_{i=1}^{D}\hat{x}_i^2 = 1
        $$

        $$
        y_i = \gamma_i\hat{x}_i
        $$

        $$
        y_i = \gamma_i
        \frac{x_i}{\sqrt{\frac{1}{D}\sum_{j=1}^{D}x_j^2 + \epsilon}}
        $$

        | Name | Formula |
        |---|---|
        | Mean | $m = \frac{1}{D}\sum x_i^2$ |

        - Inline: \(x_1 + x_2\)
        - **Bold** and $x_1 * x_2$.
        """#)
        #expect(try await renderer.count(".katex") == 10)
        #expect(try await renderer.count(".katex-display") == 7)
        #expect(try await renderer.count("table td .katex") == 1)
        #expect(try await renderer.count("li .katex") == 2)
        #expect(try await renderer.count("li strong") == 1)
        #expect(try await renderer.count(".cmux-math-error") == 0)
    }

    @Test
    func codeCurrencyAndUnclosedDelimitersRemainText() async throws {
        let renderer = MarkdownMathTestRenderer()
        defer { renderer.close() }
        try await renderer.load(#"""
        Prices: $5 and $10. Escaped: \$x\$.

        Inline code: `$x^2$` and `\(x\)`.

        HTML code: <code>$x^2$</code>.

        ```latex
        $$\frac{x}{2}$$
        ```

            $x_1$

        Unclosed: $x_1

        Unclosed: \(x_1
        """#)
        #expect(try await renderer.count(".cmux-math") == 0)
        #expect(try await renderer.count("pre code") == 2)
        let library = try await renderer.webView.evaluateJavaScript("typeof window.katex")
        #expect(library as? String == "undefined")
        let text = try await renderer.webView.evaluateJavaScript(
            "document.getElementById('content').textContent"
        ) as? String
        #expect(text?.contains("$5 and $10") == true)
        #expect(text?.contains("$x$") == true)
    }

    @Test
    func formulasAndRealMermaidRemainIndependent() async throws {
        let renderer = MarkdownMathTestRenderer()
        defer { renderer.close() }
        try await renderer.load(#"""
        Inline $x_1$.

        ```mermaid
        flowchart LR
          A["$$x^2$$"] --> B["Output"]
        ```

        $$
        \sqrt{x}
        $$
        """#)
        try await renderer.waitFor("document.querySelector('.cmux-mermaid svg .katex') !== null")
        #expect(try await renderer.count(".cmux-math .katex") == 2)
        #expect(try await renderer.count(".cmux-mermaid .cmux-math") == 0)
        #expect(try await renderer.count(".cmux-math-error, .cmux-render-error") == 0)
    }

    @Test
    func currencyBesideFormulaDoesNotConsumeIt() async throws {
        let renderer = MarkdownMathTestRenderer()
        defer { renderer.close() }
        try await renderer.load("Cost $5 and $10, formula $x$.")
        #expect(try await renderer.count(".katex") == 1)
        #expect(try await renderer.count(".cmux-math-error") == 0)
        let text = try await renderer.webView.evaluateJavaScript(
            "document.getElementById('content').textContent"
        ) as? String
        #expect(text?.contains("Cost $5 and $10, formula") == true)
    }

    @Test
    func invalidFormulaKeepsSourceAndLiveUpdatesReplaceMath() async throws {
        let renderer = MarkdownMathTestRenderer()
        defer { renderer.close() }
        try await renderer.load(#"$\unknownCmuxCommand{x}$ and $x^2$"#)
        #expect(try await renderer.count(".cmux-math-error") == 1)
        #expect(try await renderer.count(".katex") == 1)
        let source = try await renderer.webView.evaluateJavaScript(
            "document.querySelector('.cmux-math-error').textContent"
        ) as? String
        #expect(source == #"$\unknownCmuxCommand{x}$"#)

        try await renderer.update(#"Updated: \(\frac{1}{2}\)."#)
        #expect(try await renderer.count(".katex") == 1)
        #expect(try await renderer.count(".cmux-math-error") == 0)
        try await renderer.update("Plain Markdown.")
        #expect(try await renderer.count(".katex") == 0)
        #expect(try await renderer.count(".markdown-body p") == 1)
    }
}

@MainActor
private final class MarkdownMathTestRenderer {
    let coordinator = MarkdownWebRenderer.Coordinator()
    let webView: MarkdownWebView
    let theme = MarkdownWebTheme.resolve(backgroundColor: .black)

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            WeakMarkdownScriptMessageHandler(coordinator),
            name: "cmuxLib"
        )
        webView = MarkdownWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        coordinator.webView = webView
        coordinator.filePath = "/tmp/cmux-markdown-math.md"
        webView.navigationDelegate = coordinator
    }

    func close() {
        coordinator.close()
    }

    func load(_ markdown: String) async throws {
        coordinator.loadShell(theme: theme, initialMarkdown: markdown)
        try await waitFor(
            "window.__cmuxRenderMarkdown !== undefined && "
                + "document.getElementById('content').textContent.length > 0"
        )
        try await waitForMath()
    }

    func update(_ markdown: String) async throws {
        coordinator.update(markdown: markdown, theme: theme)
        try await waitForMath()
    }

    func count(_ selector: String) async throws -> Int {
        let data = try JSONSerialization.data(withJSONObject: [selector])
        let literal = try #require(String(data: data, encoding: .utf8))
        return try #require(
            try await webView.evaluateJavaScript(
                "document.querySelectorAll(\(literal)[0]).length"
            ) as? Int
        )
    }

    func waitForMath() async throws {
        try await waitFor(
            "document.querySelectorAll('.cmux-math:not([data-rendered])').length === 0"
        )
    }

    func waitFor(_ expression: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? await webView.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw MarkdownMathTimeout(expression: expression)
    }
}

private struct MarkdownMathTimeout: Error {
    let expression: String
}
