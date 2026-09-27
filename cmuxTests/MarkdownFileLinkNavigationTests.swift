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
final class MarkdownFileLinkNavigationTests {
    @Test
    func repeatedFileLinksReuseOneMarkdownTab() throws {
#if DEBUG
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-navigation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("source.md")
        let targetURL = directoryURL.appendingPathComponent("target.md")
        try "[First](target.md#first)\n[Second](target.md#second)\n"
            .write(to: sourceURL, atomically: true, encoding: .utf8)
        try "# First\n\nBody\n\n# Second\n"
            .write(to: targetURL, atomically: true, encoding: .utf8)

        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousShared }

        let manager = TabManager()
        let workspace = manager.addWorkspace(
            workingDirectory: directoryURL.path,
            select: true,
            eagerLoadTerminal: false
        )
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            for panel in workspace.panels.values {
                panel.close()
            }
        }
        TerminalController.shared.setActiveTabManager(manager)
        appDelegate.registerMainWindowContextForTesting(tabManager: manager)

        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let sourcePanel = try #require(workspace.newMarkdownSurface(
            inPane: pane,
            filePath: sourceURL.path,
            focus: true
        ))
        let coordinator = MarkdownWebRenderer.Coordinator()
        coordinator.bind(panelId: sourcePanel.id, workspaceId: workspace.id, filePath: sourceURL.path)

        coordinator.openMarkdownFileLink("target.md#first")
        let firstTargets = workspace.panels.values.compactMap { panel -> MarkdownPanel? in
            guard let markdownPanel = panel as? MarkdownPanel,
                  markdownPanel.filePath == targetURL.path else { return nil }
            return markdownPanel
        }
        let firstTarget = try #require(firstTargets.first)
        #expect(firstTargets.count == 1)

        coordinator.openMarkdownFileLink("target.md#second")
        let secondTargets = workspace.panels.values.compactMap { panel -> MarkdownPanel? in
            guard let markdownPanel = panel as? MarkdownPanel,
                  markdownPanel.filePath == targetURL.path else { return nil }
            return markdownPanel
        }
        #expect(secondTargets.count == 1)
        #expect(secondTargets.first === firstTarget)
#else
        Issue.record("Markdown file link routing requires a DEBUG app build")
#endif
    }

    @Test
    func modifiedClickRevealsMarkdownSourceAfterRerender() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 360))
        let delegate = MarkdownFileLinkShellLoadDelegate()
        try await delegate.load(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            in: webView,
            baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("source.md")
        )
        let markdown = """
        ---
        title: Example
        ---
        # 中文

        Same

        Same

        - first
          - nested

        > quote
        >
        > next

        ```swift
        let value = 1
        ```

        [Link](https://example.com)
        """
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            """
            (function() {
              var messages = [];
              var preventedMouseDowns = [];
              window.webkit = {messageHandlers: {cmuxLib: {postMessage: function(body) {
                messages.push(body);
              }}}};
              window.__cmuxRenderMarkdown(\(literal)[0].replace(/\\n/g, '\\r\\n'));
              function click(selector, index, modifiers) {
                var element = document.querySelectorAll(selector)[index || 0];
                var mouseDown = new MouseEvent('mousedown', Object.assign({
                  bubbles: true, cancelable: true, button: 0
                }, modifiers));
                element.dispatchEvent(mouseDown);
                preventedMouseDowns.push(mouseDown.defaultPrevented);
                var event = new MouseEvent('click', Object.assign({
                  bubbles: true, cancelable: true, button: 0
                }, modifiers));
                element.dispatchEvent(event);
                return event.defaultPrevented;
              }
              var gesture = {metaKey: true, shiftKey: true};
              click('h1', 0, gesture);
              click('#content > p', 1, gesture);
              click('li li', 0, gesture);
              click('blockquote p', 1, gesture);
              click('pre code.language-swift', 0, gesture);
              var prevented = click('#content > p a', 0, gesture);
              click('h1', 0, {metaKey: true});
              click('h1', 0, {shiftKey: true});
              window.__cmuxRenderMarkdown('\\n\\n# Updated');
              click('h1', 0, gesture);
              return {lines: messages.filter(function(m) {
                return m.action === 'openMarkdownSource';
              }).map(function(m) { return m.line; }), prevented: prevented,
                preventedMouseDowns: preventedMouseDowns};
            })();
            """
        )
        let snapshot = try #require(result as? [String: Any])
        #expect(snapshot["lines"] as? [Int] == [4, 8, 11, 15, 17, 21, 3])
        #expect(snapshot["prevented"] as? Bool == true)
        #expect(snapshot["preventedMouseDowns"] as? [Bool] == [
            true, true, true, true, true, true, false, false, true
        ])
    }

    @Test
    func fileLinkFragmentIsDecodedForHeadingLookup() {
        #expect(MarkdownPanelFileLinkResolver.fragment(from: "guide.md#section-two") == "section-two")
        #expect(MarkdownPanelFileLinkResolver.fragment(from: "guide.md#%E8%AF%A6%E7%BB%86%E4%BF%A1%E6%81%AF") == "详细信息")
        #expect(MarkdownPanelFileLinkResolver.fragment(from: "guide.md#") == "")
        #expect(MarkdownPanelFileLinkResolver.fragment(from: "guide.md") == nil)
    }

    @Test
    func rendererScrollsToRequestedUnicodeAnchor() async throws {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 360)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loadDelegate = MarkdownFileLinkShellLoadDelegate()
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("anchor.md")
        try await loadDelegate.load(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            in: webView,
            baseURL: baseURL
        )

        let filler = Array(repeating: "Paragraph with enough content to require scrolling.\n", count: 80)
            .joined(separator: "\n")
        let markdown = "# Start\n\n\(filler)\n\n## 详细信息\n\nTarget section.\n\n\(filler)"
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")

        let result = try await webView.evaluateJavaScript(
            """
            (function() {
              document.documentElement.style.scrollBehavior = 'auto';
              window.scrollTo(0, 0);
              var scrolled = window.__cmuxScrollToAnchor('详细信息');
              var heading = document.getElementById('详细信息');
              return {
                scrolled: scrolled,
                headingTop: heading.getBoundingClientRect().top,
                scrollY: window.scrollY
              };
            })();
            """
        )
        let snapshot = try #require(result as? [String: Any])
        #expect(snapshot["scrolled"] as? Bool == true)
        #expect((snapshot["scrollY"] as? Double ?? 0) > 0)
        #expect(abs((snapshot["headingTop"] as? Double ?? .greatestFiniteMagnitude)) <= 2)
    }
}

@MainActor
private final class MarkdownFileLinkShellLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
