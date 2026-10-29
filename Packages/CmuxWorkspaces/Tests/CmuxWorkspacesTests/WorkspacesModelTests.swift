import Foundation
import Observation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class StubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String

    init(
        id: UUID = UUID(),
        groupId: UUID? = nil,
        isPinned: Bool = false,
        currentDirectory: String = "/tmp"
    ) {
        self.id = id
        self.groupId = groupId
        self.isPinned = isPinned
        self.currentDirectory = currentDirectory
    }
}

@MainActor
private final class RecordingHost: WorkspacesHosting {
    typealias Tab = StubTab

    private(set) var events: [String] = []
    /// Snapshot of `model.tabs` taken inside the willSet hook, to prove the
    /// hook fires while storage still holds the old value (@Published parity).
    private(set) var tabsSeenDuringWillSet: [[UUID]] = []
    private(set) var groupsSeenDuringWillSet: [[UUID]] = []
    private(set) var selectionSeenDuringWillSet: [UUID?] = []
    var model: WorkspacesModel<StubTab>?
    var didChangeSelection: (() -> Void)?

    func workspaceTabsWillChange(to newValue: [StubTab]) {
        events.append("tabs.willSet(\(newValue.count))")
        if let model {
            tabsSeenDuringWillSet.append(model.tabs.map(\.id))
        }
    }

    func workspaceGroupsWillChange(to newValue: [WorkspaceGroup]) {
        events.append("groups.willSet(\(newValue.count))")
        if let model {
            groupsSeenDuringWillSet.append(model.workspaceGroups.map(\.id))
        }
    }

    func selectedWorkspaceIdWillChange(to newValue: UUID?) {
        events.append("selection.willSet")
        if let model {
            selectionSeenDuringWillSet.append(model.selectedTabId)
        }
    }

    func selectedWorkspaceIdDidChange(from oldValue: UUID?) {
        events.append("selection.didSet")
        didChangeSelection?()
    }
}

@MainActor
struct WorkspacesModelTests {
    @MainActor
    private final class ObservationCount {
        var value = 0
    }

    @Test(arguments: [true, false])
    func tabsWillSetHookFiresWhileStorageHoldsOldValue(observationEnabled: Bool) {
        let model = WorkspacesModel<StubTab>(observationEnabled: observationEnabled)
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        let first = StubTab()
        model.tabs = [first]
        let second = StubTab()
        model.tabs = [first, second]

        #expect(host.events == ["tabs.willSet(1)", "tabs.willSet(2)"])
        // During the second assignment the storage still held [first].
        #expect(host.tabsSeenDuringWillSet == [[], [first.id]])
    }

    @Test(arguments: [true, false])
    func selectionHooksFireInWillSetThenDidSetOrderWithOldAndNewValues(observationEnabled: Bool) {
        let model = WorkspacesModel<StubTab>(observationEnabled: observationEnabled)
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        let id = UUID()
        model.selectedTabId = id

        #expect(host.events == ["selection.willSet", "selection.didSet"])
        // willSet observed the pre-change storage (nil).
        #expect(host.selectionSeenDuringWillSet == [nil])
        #expect(model.selectedTabId == id)
    }

    @Test(arguments: [true, false])
    func hooksFireOnEqualValueAssignmentMatchingPublishedParity(observationEnabled: Bool) {
        let model = WorkspacesModel<StubTab>(observationEnabled: observationEnabled)
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        let id = UUID()
        model.selectedTabId = id
        model.selectedTabId = id
        model.workspaceGroups = []

        // @Published fired its observers on every assignment, equal or not;
        // no-op guards belong in the host's hook bodies.
        #expect(host.events == [
            "selection.willSet", "selection.didSet",
            "selection.willSet", "selection.didSet",
            "groups.willSet(0)",
        ])
    }

    @Test(arguments: [true, false])
    func mutationsBeforeAttachFireNoHooks(observationEnabled: Bool) {
        let model = WorkspacesModel<StubTab>(observationEnabled: observationEnabled)
        let host = RecordingHost()
        host.model = model

        model.tabs = [StubTab()]
        model.selectedTabId = UUID()
        model.attach(host: host)

        #expect(host.events.isEmpty)
        #expect(model.tabs.count == 1)
    }

    @Test(arguments: [true, false])
    func inPlaceArrayMutationFiresTabsHook(observationEnabled: Bool) {
        let model = WorkspacesModel<StubTab>(observationEnabled: observationEnabled)
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)

        model.tabs.append(StubTab())
        model.tabs.removeAll()

        #expect(host.events == ["tabs.willSet(1)", "tabs.willSet(0)"])
    }

    @Test(arguments: [true, false])
    func groupsWillSetHookSeesOldStorage(observationEnabled: Bool) {
        let model = WorkspacesModel<StubTab>(observationEnabled: observationEnabled)
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)
        let group = WorkspaceGroup(
            id: UUID(), name: "group", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil
        )

        model.workspaceGroups = [group]
        model.workspaceGroups.removeAll()

        #expect(host.groupsSeenDuringWillSet == [[], [group.id]])
        #expect(model.workspaceGroups.isEmpty)
    }

    @Test
    func defaultModelStillTracksReads() {
        let model = WorkspacesModel<StubTab>()
        let changes = ObservationCount()
        withObservationTracking {
            _ = model.tabs
        } onChange: {
            MainActor.assumeIsolated { changes.value += 1 }
        }

        model.tabs.append(StubTab())

        #expect(changes.value == 1)
    }

    @Test(arguments: [true, false])
    func selectionHostCanMutateGroupsReentrantly(observationEnabled: Bool) {
        let model = WorkspacesModel<StubTab>(observationEnabled: observationEnabled)
        let host = RecordingHost()
        host.model = model
        model.attach(host: host)
        let group = WorkspaceGroup(
            id: UUID(), name: "group", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil
        )
        host.didChangeSelection = { model.workspaceGroups = [group] }

        model.selectedTabId = group.anchorWorkspaceId

        #expect(host.events == ["selection.willSet", "selection.didSet", "groups.willSet(1)"])
        #expect(model.selectedTabId == group.anchorWorkspaceId)
        #expect(model.workspaceGroups == [group])
    }

    @Test(arguments: [true, false])
    func observationPolicyPreservesNativeTrackingAndHostHooks(observationEnabled: Bool) {
        for property in 0..<3 {
            let model = WorkspacesModel<StubTab>(observationEnabled: observationEnabled)
            let host = RecordingHost()
            host.model = model
            model.attach(host: host)
            let changes = ObservationCount()
            withObservationTracking {
                switch property {
                case 0: _ = model.tabs
                case 1: _ = model.selectedTabId
                default: _ = model.workspaceGroups
                }
            } onChange: {
                MainActor.assumeIsolated { changes.value += 1 }
            }

            switch property {
            case 0: model.tabs.append(StubTab())
            case 1: model.selectedTabId = UUID()
            default: model.workspaceGroups = []
            }

            #expect(changes.value == (observationEnabled ? 1 : 0))
            #expect(!host.events.isEmpty)
        }
    }
}
