import AppKit
import SwiftUI

/// NSHostingController whose view is a `NonDraggableHostingView`. See the comment on
/// `NonDraggableHostingView` for the rationale — this exists so call sites can keep using
/// the controller-based lifecycle (root-view swapping, sizing options, etc.) without
/// having to construct and reparent the hosting view manually.
final class NonDraggableHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = NonDraggableHostingView(rootView: rootView)
    }
}
