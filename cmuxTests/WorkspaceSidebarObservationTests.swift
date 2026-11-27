import Foundation
import Testing
import XCTest

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceSidebarObservationTests: XCTestCase {
    func testSidebarObservationPublisherEmitsForLateStatusSubscriber() {
        let workspace = Workspace()
        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    func testSidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertGreaterThan(
            publishCount,
            0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    func testSidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        XCTAssertEqual(
            publishCount,
            0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }
}

@MainActor
@Suite(.serialized)
struct TerminalProgramStatusTests {
    @Test func runningPaneKeepsWorkspaceRunningUntilItFinishes() throws {
        let workspace = Workspace()
        let runningPanelId = try #require(workspace.focusedPanelId)
        let blockedPanel = try #require(
            workspace.newTerminalSplit(from: runningPanelId, orientation: .horizontal)
        )
        var observedUpdates = 0
        let subscription = workspace.sidebarObservationPublisher.sink { observedUpdates += 1 }
        defer { subscription.cancel() }
        let initialUpdates = observedUpdates

        workspace.updateTerminalProgramStatus(
            panelId: runningPanelId, agent: .codex, sessionID: nil, state: .working
        )
        workspace.updateTerminalProgramStatus(
            panelId: blockedPanel.id, agent: .codex, sessionID: nil, state: .blocked
        )
        #expect(workspace.sidebarStatusEntriesInDisplayOrder().map(\.icon) == ["bolt.fill"])
        #expect(observedUpdates > initialUpdates)

        workspace.updateTerminalProgramStatus(
            panelId: runningPanelId, agent: .codex, sessionID: nil, state: .idle
        )
        #expect(workspace.sidebarStatusEntriesInDisplayOrder().map(\.icon) == ["bell.fill"])

        workspace.updateTerminalProgramStatus(
            panelId: blockedPanel.id, agent: .codex, sessionID: nil, state: .clear
        )
        #expect(workspace.sidebarStatusEntriesInDisplayOrder().isEmpty)
    }

    @Test func lateHookStatusDoesNotOverrideTerminalState() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.recordAgentPID(key: "codex.session", pid: getpid(), panelId: panelId)
        workspace.updateTerminalProgramStatus(
            panelId: panelId, agent: .codex, sessionID: nil, state: .idle
        )
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "late hook")

        #expect(workspace.sidebarStatusEntriesInDisplayOrder().isEmpty)

        workspace.updateTerminalProgramStatus(
            panelId: panelId, agent: .codex, sessionID: nil, state: .working
        )
        #expect(workspace.sidebarStatusEntriesInDisplayOrder().map(\.icon) == ["bolt.fill"])
    }

    @Test func claudeAndCodexKeepIndependentStatusesOnTheSamePanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.updateTerminalProgramStatus(
            panelId: panelId, agent: .codex, sessionID: nil, state: .working
        )
        workspace.updateTerminalProgramStatus(
            panelId: panelId, agent: .claude, sessionID: nil, state: .blocked
        )
        workspace.updateTerminalProgramStatus(
            panelId: panelId, agent: .claude, sessionID: "background", state: .working
        )
        func icons() -> [String: String] {
            Dictionary(uniqueKeysWithValues: workspace.sidebarStatusEntriesInDisplayOrder().map {
                ($0.key, $0.icon ?? "")
            })
        }

        #expect(icons() == ["codex": "bolt.fill", "claude_code": "bolt.fill"])
        workspace.updateTerminalProgramStatus(
            panelId: panelId, agent: nil, sessionID: "background", state: .clear
        )
        #expect(icons() == ["codex": "bolt.fill", "claude_code": "bell.fill"])
        workspace.updateTerminalProgramStatus(
            panelId: panelId, agent: .claude, sessionID: nil, state: .clear
        )
        #expect(icons() == ["codex": "bolt.fill"])
    }

    @Test func claudeNotificationsFollowTransitionsAndDeferToRegisteredHooks() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        func report(_ state: Workspace.TerminalProgramState) -> Bool {
            workspace.updateTerminalProgramStatus(
                panelId: panelId, agent: .claude, sessionID: "session", state: state
            )
        }

        #expect(!report(.done))
        #expect(!report(.working))
        #expect(report(.blocked))
        #expect(!report(.blocked))
        #expect(report(.done))
        #expect(!report(.done))
        #expect(!report(.working))
        #expect(report(.error))
        #expect(!report(.error))

        workspace.recordAgentPID(key: "claude_code.session", pid: getpid(), panelId: panelId)
        #expect(!report(.working))
        #expect(!report(.blocked))
        #expect(workspace.sidebarStatusEntriesInDisplayOrder().map(\.key) == ["claude_code"])
        #expect(!report(.done))
    }

#if DEBUG
    @Test func claudeOSCCompletionRecordsDecodedNotificationOnce() async throws {
        let app = try #require(AppDelegate.shared)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
        let store = TerminalNotificationStore.shared
        let previousFocusOverride = AppFocusState.overrideIsFocused
        var deliveries = 0
        AppFocusState.overrideIsFocused = true
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in deliveries += 1 }
        defer {
            AppFocusState.overrideIsFocused = previousFocusOverride
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            store.clearNotifications(forTabId: workspace.id)
            panel.surface.teardownSurface()
            app.unregisterMainWindowContextForTesting(windowId: windowID)
        }

        panel.surface.requestBackgroundSurfaceStartIfNeeded()
        for _ in 0..<100 where panel.surface.surface == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let runtime = panel.surface.liveSurfaceForGhosttyAccess(reason: "osc7501NotificationTest")
        let surface = try #require(runtime)
        try #require(manager.focusedSurfaceId(for: workspace.id) == panelID)
        let reports = [
            "state=working:app=claude-code",
            "state=done:app=claude-code:title=Q2hlY2tz:msg=UGFzc2Vk",
            "state=done:app=claude-code:title=Q2hlY2tz:msg=UGFzc2Vk"
        ]
        let output = Data(reports.map { "\u{1B}]7501;\($0)\u{1B}\\" }.joined().utf8)
        output.withUnsafeBytes { buffer in
            guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(surface, bytes, UInt(buffer.count))
        }
        for _ in 0..<100 where store.latestNotification(forTabId: workspace.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let notification = try #require(store.latestNotification(forTabId: workspace.id))
        #expect(notification.surfaceId == panelID)
        #expect(notification.title == AgentSessionProviderID.claude.displayName)
        #expect(notification.subtitle == "Checks")
        #expect(notification.body == "Passed")
        #expect(deliveries == 1)
    }
#endif
}
