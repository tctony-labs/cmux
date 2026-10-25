import AppKit
import SwiftUI

@MainActor
final class MainWindowHostingView<Content: View>: NSHostingView<Content> {
    private let zeroSafeAreaLayoutGuide = NSLayoutGuide()
    private let screenLockObserver: ScreenLockObserver
    private let renderingNotificationCenter: NotificationCenter
    private var hasDeferredLayout = false
    // Only the main actor mutates these tokens; NotificationCenter removal is thread-safe.
    private nonisolated(unsafe) var renderingStateObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var occlusionObserver: (any NSObjectProtocol)?

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var safeAreaLayoutGuide: NSLayoutGuide { zeroSafeAreaLayoutGuide }
    override var mouseDownCanMoveWindow: Bool { false }
    override var fittingSize: NSSize { CmuxMainWindow.minimumContentSize }
    override var intrinsicContentSize: NSSize { CmuxMainWindow.minimumContentSize }

    /// Lets a click on an interactive titlebar control (the sidebar toggle, the
    /// right-sidebar mode bar, the session-index header controls, etc.) both
    /// activate the window and trigger the control in a single click when the
    /// window is inactive — matching how macOS services controls in the titlebar.
    ///
    /// Scoped to registered ``MinimalModeTitlebarControlHitRegionRegistry`` regions
    /// (the regions `titlebarInteractiveControl()` registers) so clicking inactive
    /// *content* still only activates the window. This recovers the first-mouse
    /// behavior the previous nested-`NSHostingView` host provided, without
    /// reparenting the control (which dropped active-window clicks in the
    /// full-size-content titlebar band — issue #5099).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event, let window else { return false }
        return isMinimalModeTitlebarControlHit(window: window, locationInWindow: event.locationInWindow)
    }

    required convenience init(rootView: Content) {
        self.init(rootView: rootView, screenLockObserver: .shared)
    }

    init(rootView: Content, screenLockObserver: ScreenLockObserver) {
        self.screenLockObserver = screenLockObserver
        renderingNotificationCenter = screenLockObserver.notificationCenter
        super.init(rootView: rootView)
        // AppKit owns window geometry; the overrides above supply its minimum.
        // macOS 14 still measures SwiftUI content during updateConstraints,
        // accumulating observations while hidden unless automatic sizing is off.
        sizingOptions = []
        addLayoutGuide(zeroSafeAreaLayoutGuide)
        NSLayoutConstraint.activate([
            zeroSafeAreaLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            zeroSafeAreaLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            zeroSafeAreaLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            zeroSafeAreaLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        renderingStateObserver = renderingNotificationCenter.addObserver(
            forName: ScreenLockObserver.renderingStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let source = notification.object as? ScreenLockObserver,
                      source === self.screenLockObserver else { return }
                self.resumeDeferredLayoutIfPossible()
            }
        }
    }

    private var shouldDeferLayout: Bool {
        if screenLockObserver.isRenderingSuspended || isHiddenOrHasHiddenAncestor { return true }
        return window.map { !$0.occlusionState.contains(.visible) } ?? false
    }

    override var needsLayout: Bool {
        // AppKit must not continuously retry a dirty SwiftUI graph while the
        // session cannot render it. Preserve the request for the resume pass.
        get { !shouldDeferLayout && super.needsLayout }
        set {
            if newValue, shouldDeferLayout {
                hasDeferredLayout = true
            } else {
                super.needsLayout = newValue
            }
        }
    }

    override func layout() {
        // Even with sizingOptions disabled, ordinary hidden layout evaluates
        // SwiftUI and accumulates observations on macOS 14. A locked session
        // can still report its windows as visible, so check both sources.
        guard !shouldDeferLayout else {
            hasDeferredLayout = true
            return
        }
        hasDeferredLayout = false
        super.layout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeDeferredLayoutIfPossible() }
            }
        }
        resumeDeferredLayoutIfPossible()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        resumeDeferredLayoutIfPossible()
    }

    private func resumeDeferredLayoutIfPossible() {
        guard hasDeferredLayout, !shouldDeferLayout else { return }
        // Request one AppKit pass with the latest model and geometry. Do not
        // replay the layouts skipped while locked or force a drawing loop.
        needsLayout = true
    }

    // Swift 6.2 crashes lowering isolated deinit on this generic NSHostingView subclass.
    deinit {
        if let token = renderingStateObserver { renderingNotificationCenter.removeObserver(token) }
        if let token = occlusionObserver { NotificationCenter.default.removeObserver(token) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
func configureCmuxMainWindowDragBehavior(_ window: NSWindow) {
    window.isMovableByWindowBackground = false
    window.isMovable = false
}

@MainActor
final class CmuxMainWindow: NSWindow {
    static var minimumContentSize: NSSize {
        NSSize(
            width: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
            height: CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        )
    }

    static func standardFrame(forDefaultFrame defaultFrame: NSRect) -> NSRect {
        let minimumSize = minimumContentSize
        var frame = defaultFrame
        frame.size.width = max(frame.size.width, minimumSize.width)
        frame.size.height = max(frame.size.height, minimumSize.height)
        return frame
    }

    private var isSoftHiddenForVisibilityController = false

    func setSoftHiddenForVisibilityController(_ isSoftHidden: Bool) {
        isSoftHiddenForVisibilityController = isSoftHidden
        if isSoftHidden {
            makeFirstResponder(nil)
            ignoresMouseEvents = true
            alphaValue = 0
        } else {
            alphaValue = 1
            ignoresMouseEvents = false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.flagsChanged(with: event)
    }
}

extension CmuxMainWindow {
    private static let defaultContentSize = NSSize(width: 1_000, height: 700)

    /// Returns an unpositioned content rect clamped to the visible display; callers own final placement.
    static func defaultContentRect(styleMask: NSWindow.StyleMask) -> NSRect {
        let unpositionedContentRect = NSRect(origin: .zero, size: defaultContentSize)
        guard let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return unpositionedContentRect
        }

        let frameRect = NSWindow.frameRect(forContentRect: unpositionedContentRect, styleMask: styleMask)
        let clampedFrameRect = clampedFrame(frameRect, within: visibleFrame)
        return NSWindow.contentRect(forFrameRect: clampedFrameRect, styleMask: styleMask)
    }

    private static func clampedFrame(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

        let width = min(max(frame.width, defaultContentSize.width), visibleFrame.width)
        let height = min(max(frame.height, defaultContentSize.height), visibleFrame.height)
        return NSRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }
}
