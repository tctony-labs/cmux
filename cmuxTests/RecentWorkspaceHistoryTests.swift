import Foundation
import CmuxCommandPalette
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct RecentWorkspaceHistoryTests {
    @Test
    func repositoryDeduplicatesByNormalizedDirectoryAndKeepsNewestOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = RecentWorkspaceHistoryRepository(fileURL: fixture.fileURL)
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)

        let first = await repository.recordOpened(
            directory: fixture.directoryURL.appendingPathComponent("project/../project").path,
            displayName: "Old Name",
            openedAt: older
        )
        let firstID = try #require(first.entries.first?.id)
        let second = await repository.recordOpened(
            directory: fixture.directoryURL.appendingPathComponent("project").path,
            displayName: "New Name",
            openedAt: newer
        )
        _ = await repository.recordOpened(
            directory: fixture.directoryURL.appendingPathComponent("project").path,
            displayName: "Stale Name",
            openedAt: older
        )
        let snapshot = await repository.snapshot()

        #expect(second.entries.count == 1)
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].id == firstID)
        #expect(snapshot.entries[0].displayName == "New Name")
        #expect(snapshot.entries[0].lastOpenedAt == newer)
    }

    @Test
    func repositoryPersistsSortOrderAndRemovesOneEntry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = RecentWorkspaceHistoryRepository(fileURL: fixture.fileURL)
        let first = await repository.recordOpened(
            directory: fixture.directoryURL.appendingPathComponent("first").path,
            displayName: "First",
            openedAt: Date(timeIntervalSince1970: 100)
        )
        let firstID = try #require(first.entries.first?.id)
        _ = await repository.recordOpened(
            directory: fixture.directoryURL.appendingPathComponent("second").path,
            displayName: "Second",
            openedAt: Date(timeIntervalSince1970: 200)
        )
        _ = await repository.updateTitle(
            directory: fixture.directoryURL.appendingPathComponent("first").path,
            displayName: "Renamed First",
            customTitle: "Renamed First"
        )

        let restored = RecentWorkspaceHistoryRepository(fileURL: fixture.fileURL)
        let restoredSnapshot = await restored.snapshot()
        #expect(restoredSnapshot.entries.map(\.displayName) == ["Second", "Renamed First"])
        #expect(restoredSnapshot.entries[1].customTitle == "Renamed First")

        let afterRemoval = await restored.remove(id: firstID)
        #expect(afterRemoval.entries.map(\.displayName) == ["Second"])

        let finalID = try #require(afterRemoval.entries.first?.id)
        let empty = await restored.remove(id: finalID)
        #expect(empty.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test
    @MainActor
    func workspaceRenameUpdatesHistoryAndQuickOpenRestoresCustomTitle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var updatedTitle: (displayName: String, customTitle: String?)?
        let manager = TabManager()
        manager.attachRecentWorkspaceHistory(
            recordOpened: { _, _, _, _ in },
            updateTitle: { _, displayName, customTitle in
                updatedTitle = (displayName, customTitle)
            }
        )
        let workspace = manager.addWorkspaceForQuickOpenDirectory(fixture.directoryURL)

        manager.setCustomTitle(tabId: workspace.id, title: "Renamed Workspace")

        #expect(updatedTitle?.displayName == "Renamed Workspace")
        #expect(updatedTitle?.customTitle == "Renamed Workspace")
        let reopened = manager.addWorkspaceForQuickOpenDirectory(
            fixture.directoryURL,
            customTitle: updatedTitle?.customTitle
        )
        #expect(reopened.customTitle == "Renamed Workspace")
        #expect(reopened.title == "Renamed Workspace")
    }

    @Test
    func legacyEntryUsesStoredDisplayNameAsCustomTitle() throws {
        let id = UUID()
        let data = Data("""
        {
          "id": "\(id.uuidString)",
          "directory": "/tmp/legacy-workspace",
          "displayName": "Previously Renamed",
          "lastOpenedAt": 0
        }
        """.utf8)

        let entry = try JSONDecoder().decode(RecentWorkspaceHistoryEntry.self, from: data)

        #expect(entry.customTitle == "Previously Renamed")
        let encoded = try JSONEncoder().encode(RecentWorkspaceHistoryEntry(
            id: id,
            directory: "/tmp/new-workspace",
            displayName: "New Workspace",
            customTitle: nil,
            lastOpenedAt: Date(timeIntervalSinceReferenceDate: 0)
        ))
        let encodedObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(encodedObject.keys.contains("customTitle"))
        #expect(encodedObject["customTitle"] is NSNull)
    }

    @Test
    func displayDirectoryUsesTildeOnlyForPathsInsideHome() {
        #expect(RecentWorkspaceHistoryEntry.displayDirectory(
            "/Users/tester",
            homeDirectory: "/Users/tester"
        ) == "~")
        #expect(RecentWorkspaceHistoryEntry.displayDirectory(
            "/Users/tester/projects/cmux",
            homeDirectory: "/Users/tester"
        ) == "~/projects/cmux")
        #expect(RecentWorkspaceHistoryEntry.displayDirectory(
            "/Users/tester-archive/cmux",
            homeDirectory: "/Users/tester"
        ) == "/Users/tester-archive/cmux")
    }

    @Test
    func switcherGroupsOpenBeforeRecentAndSortsRecentByRank() {
        let open = result(id: "switcher.workspace.open", rank: 50, title: "Open")
        let newest = result(id: "switcher.recentWorkspace.newest", rank: 1, title: "Newest")
        let older = result(id: "switcher.recentWorkspace.older", rank: 2, title: "Older")

        let grouped = ContentView.commandPaletteGroupedSwitcherResults(
            [older, newest, open],
            scope: .switcher
        )

        #expect(grouped.map(\.id) == [open.id, newest.id, older.id])
    }

    @Test
    func switcherExcludesRecentEntriesWhoseDirectoryIsOpen() {
        let open = RecentWorkspaceHistoryEntry(
            directory: "/tmp/open",
            displayName: "Open",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let recent = RecentWorkspaceHistoryEntry(
            directory: "/tmp/recent",
            displayName: "Recent",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )

        let available = ContentView.commandPaletteAvailableRecentWorkspaceEntries(
            [open, recent],
            openDirectories: ["/tmp/open"]
        )

        #expect(available.map(\.id) == [recent.id])
    }

    private func result(id: String, rank: Int, title: String) -> CommandPaletteSearchResult {
        CommandPaletteSearchResult(
            command: CommandPaletteCommand(
                id: id,
                rank: rank,
                title: title,
                subtitle: "",
                shortcutHint: nil,
                kindLabel: nil,
                keywords: [],
                dismissOnRun: true,
                action: {}
            ),
            score: 0,
            titleMatchIndices: []
        )
    }

    private struct Fixture {
        let directoryURL: URL
        let fileURL: URL

        init() throws {
            directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RecentWorkspaceHistoryTests-\(UUID().uuidString)")
            fileURL = directoryURL.appendingPathComponent("history.json")
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }
}
