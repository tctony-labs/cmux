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
struct TerminalCodexSidebarStatusTests {
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

        workspace.updateTerminalCodexStatus(panelId: runningPanelId, status: .running)
        workspace.updateTerminalCodexStatus(panelId: blockedPanel.id, status: .needsInput)
        #expect(workspace.sidebarStatusEntriesInDisplayOrder().map(\.icon) == ["bolt.fill"])
        #expect(observedUpdates > initialUpdates)

        workspace.updateTerminalCodexStatus(panelId: runningPanelId, status: .idle)
        #expect(workspace.sidebarStatusEntriesInDisplayOrder().map(\.icon) == ["bell.fill"])

        workspace.updateTerminalCodexStatus(panelId: blockedPanel.id, status: nil)
        #expect(workspace.sidebarStatusEntriesInDisplayOrder().isEmpty)
    }

    @Test func lateHookStatusDoesNotOverrideTerminalState() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.recordAgentPID(key: "codex.session", pid: getpid(), panelId: panelId)
        workspace.updateTerminalCodexStatus(panelId: panelId, status: .idle)
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "late hook")

        #expect(workspace.sidebarStatusEntriesInDisplayOrder().isEmpty)

        workspace.updateTerminalCodexStatus(panelId: panelId, status: .running)
        #expect(workspace.sidebarStatusEntriesInDisplayOrder().map(\.icon) == ["bolt.fill"])
    }
}
