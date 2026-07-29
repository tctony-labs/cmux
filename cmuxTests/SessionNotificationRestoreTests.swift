import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SessionNotificationRestoreTests {
    @Test
    func legacyNotificationTextAndUnreadStateAreDiscarded() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalNotificationStore = appDelegate.notificationStore
        appDelegate.notificationStore = store
        store.replaceNotificationsForTesting([])
        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == panelId })
        snapshot.hasUnreadIndicator = true
        snapshot.panels[panelIndex].hasUnreadIndicator = true
        snapshot.panels[panelIndex].restoredUnreadContributesToWorkspace = false
        snapshot.panels[panelIndex].notifications = [
            SessionNotificationSnapshot(
                id: UUID(),
                title: "Agent finished",
                subtitle: "codex",
                body: "Previous iMessage",
                createdAt: 1_700_000_000,
                isRead: false,
                paneFlash: true
            )
        ]

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try #require(restored.focusedPanelId)
        #expect(store.latestNotification(forTabId: restored.id) == nil)
        #expect(store.sidebarUnread.latestNotificationText(forWorkspaceId: restored.id) == nil)
        #expect(!restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        #expect(!store.hasRestoredUnreadIndicator(forTabId: restored.id))
        #expect(store.unreadCount(forTabId: restored.id) == 0)
    }

    @Test
    func newSessionSnapshotDoesNotPersistNotificationText() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalNotificationStore = appDelegate.notificationStore
        appDelegate.notificationStore = store
        store.replaceNotificationsForTesting([])
        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: panelId,
                panelId: panelId,
                title: "Agent finished",
                subtitle: "codex",
                body: "Previous iMessage",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                isRead: false,
                paneFlash: true
            )
        ])

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panelId })
        #expect(panelSnapshot.notifications == nil)
        #expect(panelSnapshot.hasUnreadIndicator == nil)
    }
}
