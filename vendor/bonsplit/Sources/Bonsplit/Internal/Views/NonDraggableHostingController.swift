import AppKit
import SwiftUI

/// Hosting controller for pane content whose geometry is owned by AppKit.
/// Uses a non-draggable host on systems that call the custom `loadView`.
final class NonDraggableHostingController<Content: View>: NSHostingController<Content> {
    override init(rootView: Content) {
        super.init(rootView: rootView)
        // Pane geometry belongs to the AppKit container. On macOS 14, measuring
        // updated content while hidden accumulates Observation registrations
        // until rendering resumes; cancelling them can stall the main thread.
        // Configure the actual host, including on systems where the controller
        // creates it during initialization without calling our loadView.
        sizingOptions = []
        (view as? NSHostingView<Content>)?.sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NonDraggableHostingView(rootView: rootView)
    }
}
