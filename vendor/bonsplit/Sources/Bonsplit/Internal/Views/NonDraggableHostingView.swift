import AppKit
import SwiftUI

/// NSHostingView subclass that refuses to act as a window-drag handle.
///
/// Bonsplit nests SwiftUI panes inside their own `NSHostingController` instances
/// (via `SinglePaneWrapper` and `SplitContainerView.makeHostingController`).
/// The default `NSHostingView` returned by `NSHostingController.view` inherits the
/// AppKit default of `mouseDownCanMoveWindow == true` when the view appears opaque.
/// In `presentationMode == "minimal"` (where the window has no titlebar drag region)
/// AppKit was treating clicks on pane tab bars as window-drag intents and stealing the
/// mouseUp before the SwiftUI tap gesture could fire — making split pane tabs
/// completely unclickable. Routing clicks through this subclass keeps the entire pane
/// hosting chain non-draggable so SwiftUI gesture recognizers receive every click.
final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
