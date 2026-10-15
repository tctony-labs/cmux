import AppKit
import Observation
import SwiftUI
import Testing
@testable import Bonsplit

@MainActor
@Suite("Pane hosting sizing")
struct PaneHostingSizingTests {
    @Observable
    final class Model {
        var value = 0
    }

    final class Probe {
        var bodyEvaluations = 0
        var renderedValue: Int?
        var nativeView: NSView?
    }

    struct Content: View {
        let model: Model
        let probe: Probe
        let revision: Int

        var body: some View {
            probe.bodyEvaluations += 1
            return NativeContent(value: model.value + revision, probe: probe)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    struct NativeContent: NSViewRepresentable {
        let value: Int
        let probe: Probe

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            probe.nativeView = view
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            probe.renderedValue = value
        }
    }

    @Test
    func hiddenPaneMeasurementsDoNotRepeatedlyEvaluateObservableContent() {
        _ = NSApplication.shared
        let model = Model()
        let probe = Probe()
        let controller = NonDraggableHostingController(
            rootView: Content(model: model, probe: probe, revision: 0)
        )
        let host = controller.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }

        // AppKit may query these sizes while an occluded pane receives root
        // updates. On macOS 14 each evaluation registers another observation
        // that survives until rendering resumes, even for unchanged data.
        for revision in 0..<512 {
            controller.rootView = Content(model: model, probe: probe, revision: revision)
            _ = host.fittingSize
            _ = host.intrinsicContentSize
        }

        #expect(probe.bodyEvaluations <= 1)
        #expect(!window.isVisible)
    }

    @Test
    func layoutRendersLatestContentAndFollowsContainerResize() throws {
        _ = NSApplication.shared
        let model = Model()
        let probe = Probe()
        let controller = NonDraggableHostingController(
            rootView: Content(model: model, probe: probe, revision: 0)
        )
        let host = controller.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }

        for revision in 0..<32 {
            controller.rootView = Content(model: model, probe: probe, revision: revision)
            _ = host.fittingSize
        }
        host.layout()
        #expect(probe.renderedValue == 31)

        model.value = 100
        window.setContentSize(NSSize(width: 640, height: 480))
        host.layout()
        #expect(probe.renderedValue == 131)
        let nativeView = try #require(probe.nativeView)
        #expect(nativeView.frame.size == host.bounds.size)
        #expect(host.bounds.size == NSSize(width: 640, height: 480))
    }
}
