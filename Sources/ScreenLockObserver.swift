import AppKit
import CoreGraphics
import Foundation

/// There is no public synchronous "is the screen locked" query on macOS. Two
/// de-facto sources exist: the `CGSSessionScreenIsLocked` key in
/// `CGSessionCopyCurrentDictionary()` and the `com.apple.screenIsLocked` /
/// `com.apple.screenIsUnlocked` distributed notifications. Either can be
/// absent in a given macOS version or session context, so the live provider
/// ORs both (`MacPresenceMonitor.consoleSessionActiveAndUnlocked`). If both
/// miss a lock, the failure mode is bounded: the 120 s hardware-idle rule
/// flips the Mac to away on its own shortly after the user leaves.
/// Hosting views also use this cached state to coalesce layout while locked,
/// asleep, or switched out, without querying WindowServer during each layout.
@MainActor
final class ScreenLockObserver {
    static let shared = ScreenLockObserver()
    static let renderingStateDidChangeNotification = Notification.Name("cmux.renderingSuspensionDidChange")

    private(set) var isLockedObserved: Bool
    private var areDisplaysAsleep: Bool
    private var isSessionActive: Bool
    private var isSystemAsleep = false
    let notificationCenter: NotificationCenter

    var isRenderingSuspended: Bool {
        isLockedObserved || areDisplaysAsleep || isSystemAsleep || !isSessionActive
    }

    private var observerTokens: [(NotificationCenter, any NSObjectProtocol)] = []

    private convenience init() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        self.init(
            lockNotificationCenter: DistributedNotificationCenter.default(),
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
            notificationCenter: .default,
            initiallyLocked: (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false,
            initiallyDisplaysAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            initiallySessionActive: (session?[kCGSessionOnConsoleKey as String] as? Bool) ?? false
        )
    }

    init(
        lockNotificationCenter: NotificationCenter,
        workspaceNotificationCenter: NotificationCenter,
        notificationCenter: NotificationCenter,
        initiallyLocked: Bool,
        initiallyDisplaysAsleep: Bool = false,
        initiallySessionActive: Bool = true
    ) {
        self.notificationCenter = notificationCenter
        isLockedObserved = initiallyLocked
        areDisplaysAsleep = initiallyDisplaysAsleep
        isSessionActive = initiallySessionActive

        observe(Notification.Name("com.apple.screenIsLocked"), from: lockNotificationCenter) {
            $0.update(locked: true)
        }
        observe(Notification.Name("com.apple.screenIsUnlocked"), from: lockNotificationCenter) {
            $0.update(locked: false)
        }
        observe(NSWorkspace.screensDidSleepNotification, from: workspaceNotificationCenter) {
            $0.update(displaysAsleep: true)
        }
        observe(NSWorkspace.screensDidWakeNotification, from: workspaceNotificationCenter) {
            $0.update(displaysAsleep: false)
        }
        observe(NSWorkspace.willSleepNotification, from: workspaceNotificationCenter) {
            $0.update(systemAsleep: true)
        }
        observe(NSWorkspace.didWakeNotification, from: workspaceNotificationCenter) {
            $0.update(systemAsleep: false)
        }
        observe(NSWorkspace.sessionDidResignActiveNotification, from: workspaceNotificationCenter) {
            $0.update(sessionActive: false)
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, from: workspaceNotificationCenter) {
            $0.update(sessionActive: true)
        }
    }

    isolated deinit {
        for (center, token) in observerTokens {
            center.removeObserver(token)
        }
    }

    private func observe(
        _ name: Notification.Name,
        from center: NotificationCenter,
        action: @escaping @MainActor @Sendable (ScreenLockObserver) -> Void
    ) {
        // AppKit layout needs the cached state changed synchronously before
        // the next layout callback, so bridge these notifications on .main.
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observerTokens.append((center, token))
    }

    private func update(
        locked: Bool? = nil,
        displaysAsleep: Bool? = nil,
        sessionActive: Bool? = nil,
        systemAsleep: Bool? = nil
    ) {
        let wasSuspended = isRenderingSuspended
        if let locked { isLockedObserved = locked }
        if let displaysAsleep { areDisplaysAsleep = displaysAsleep }
        if let sessionActive { isSessionActive = sessionActive }
        if let systemAsleep { isSystemAsleep = systemAsleep }
        guard wasSuspended != isRenderingSuspended else { return }
        notificationCenter.post(name: Self.renderingStateDidChangeNotification, object: self)
    }
}
