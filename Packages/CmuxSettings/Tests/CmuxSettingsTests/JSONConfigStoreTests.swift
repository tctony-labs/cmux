import Foundation
import Testing
@testable import CmuxSettings

@Suite("JSONConfigStore")
struct JSONConfigStoreTests {
    private func makeStore() -> (JSONConfigStore, URL, SettingCatalog) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        return (JSONConfigStore(fileURL: fileURL), fileURL, SettingCatalog())
    }

    @Test func readsDefaultWhenFileMissing() async {
        let (store, _, _) = makeStore()
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "")
    }

    @Test func roundTripsNestedKey() async throws {
        let (store, fileURL, _) = makeStore()
        try await store.set("hunter2", for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "hunter2")

        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let automation = parsed?["automation"] as? [String: Any]
        #expect(automation?["socketPassword"] as? String == "hunter2")
    }

    @Test func resetRemovesEntryAndPrunesEmptyParents() async throws {
        let (store, fileURL, _) = makeStore()
        try await store.set("hunter2", for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        try await store.reset(JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "")
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["automation"] == nil)
    }

    @Test func toleratesJSONCComments() async throws {
        let (store, fileURL, _) = makeStore()
        let json = """
        {
          // commented
          "automation": {
            "socketPassword": "test",
          }
        }
        """
        try Data(json.utf8).write(to: fileURL)
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "test")
    }

    @Test func observesExternalEdit() async throws {
        let (store, fileURL, _) = makeStore()
        try Data("{}".utf8).write(to: fileURL)

        let observed = Task<[String], Never> {
            var collected: [String] = []
            for await value in store.values(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: "")) {
                collected.append(value)
                if collected.count == 2 { break }
            }
            return collected
        }

        // Give the subscriber Task time to register before the file change;
        // DispatchSource also coalesces events, so wait for delivery to settle.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let payload = #"{"automation":{"socketPassword":"injected"}}"#
        try Data(payload.utf8).write(to: fileURL)

        let collected = await withTimeout(seconds: 3) { await observed.value }
        #expect(collected.first == "")
        #expect(collected.last == "injected")
    }

    @Test func snapshotReflectsWrites() async throws {
        let (store, _, _) = makeStore()
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        #expect(store.snapshotValue(for: key) == "")

        try await store.set("LG HDR 4K", for: key)
        #expect(store.snapshotValue(for: key) == "LG HDR 4K")

        try await store.reset(key)
        #expect(store.snapshotValue(for: key) == "")
    }

    @Test func snapshotMatchesAsyncRead() async throws {
        let (store, _, _) = makeStore()
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        try await store.set("hunter2", for: key)
        let async = await store.value(for: key)
        #expect(store.snapshotValue(for: key) == async)
    }

    @Test func snapshotReadsOnDiskValueForFreshStore() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        let payload = #"{"app":{"devWindowDisplay":"LG HDR 4K"}}"#
        try Data(payload.utf8).write(to: fileURL)

        // Brand-new store, no async read first: the synchronous read goes
        // straight to disk and reflects the on-disk value.
        let store = JSONConfigStore(fileURL: fileURL)
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        #expect(store.snapshotValue(for: key) == "LG HDR 4K")
    }

    @Test func snapshotReflectsExternalEdit() async throws {
        let (store, fileURL, _) = makeStore()
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        #expect(store.snapshotValue(for: key) == "")

        // A direct disk read picks up an external edit immediately, with no
        // observer subscription or actor round-trip.
        try Data(#"{"app":{"devWindowDisplay":"LG HDR 4K"}}"#.utf8).write(to: fileURL)
        #expect(store.snapshotValue(for: key) == "LG HDR 4K")
    }

    @Test func devWindowDisplayCatalogKeyRoundTripsToSharedPath() async throws {
        let (store, fileURL, catalog) = makeStore()
        try await store.set("LG HDR 4K", for: catalog.app.devWindowDisplay)

        // Async and sync reads agree on the catalog key.
        #expect(await store.value(for: catalog.app.devWindowDisplay) == "LG HDR 4K")
        #expect(store.snapshotValue(for: catalog.app.devWindowDisplay) == "LG HDR 4K")

        // It lands at app.devWindowDisplay in cmux.json — the shared on-disk
        // shape the CLI, the app's window hook, and the Debug menu all read.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        #expect(app?["devWindowDisplay"] as? String == "LG HDR 4K")

        try await store.reset(catalog.app.devWindowDisplay)
        #expect(store.snapshotValue(for: catalog.app.devWindowDisplay) == "")
    }

    @Test func shortcutBindingsDecodeEverySupportedJSONRepresentation() async throws {
        let (store, fileURL, catalog) = makeStore()
        let payload = #"""
        {
          "shortcuts": {
            "bindings": {
              "newTab": "cmd+r",
              "newSurface": ["ctrl+b", "c"],
              "renameTab": null,
              "focusLeft": {
                "first": {
                  "key": "h",
                  "command": true,
                  "shift": false,
                  "option": false,
                  "control": true,
                  "keyCode": 4
                }
              }
            }
          }
        }
        """#
        try Data(payload.utf8).write(to: fileURL)

        let bindings = await store.value(for: catalog.shortcuts.bindings)

        #expect(bindings[ShortcutAction.newTab.rawValue] == StoredShortcut(
            first: ShortcutStroke(key: "r", command: true)
        ))
        #expect(bindings[ShortcutAction.newSurface.rawValue] == StoredShortcut(
            first: ShortcutStroke(key: "b", control: true),
            second: ShortcutStroke(key: "c")
        ))
        #expect(bindings[ShortcutAction.renameTab.rawValue] == .unbound)
        #expect(bindings[ShortcutAction.focusLeft.rawValue] == StoredShortcut(
            first: ShortcutStroke(key: "h", command: true, control: true, keyCode: 4)
        ))
    }

    @Test func updatingOneShortcutPreservesSiblingsAndReloadsTheNewValue() async throws {
        let (store, fileURL, catalog) = makeStore()
        let payload = #"""
        {
          "shortcuts": {
            "bindings": {
              "newTab": "cmd+r",
              "renameTab": null
            }
          }
        }
        """#
        try Data(payload.utf8).write(to: fileURL)

        let focusLeft = StoredShortcut(first: ShortcutStroke(key: "←", command: true, control: true))
        let focusLeftKey = JSONKey<StoredShortcut>(
            id: "shortcuts.bindings.focusLeft",
            defaultValue: .unbound
        )
        try await store.set(focusLeft, for: focusLeftKey)

        let rawRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let shortcuts = rawRoot?["shortcuts"] as? [String: Any]
        let rawBindings = shortcuts?["bindings"] as? [String: Any]
        #expect(rawBindings?[ShortcutAction.newTab.rawValue] as? String == "cmd+r")
        #expect(rawBindings?[ShortcutAction.renameTab.rawValue] is NSNull)
        #expect(rawBindings?[ShortcutAction.focusLeft.rawValue] is [String: Any])

        let reopenedStore = JSONConfigStore(fileURL: fileURL)
        let reopenedBindings = await reopenedStore.value(for: catalog.shortcuts.bindings)
        #expect(reopenedBindings[ShortcutAction.newTab.rawValue] == StoredShortcut(
            first: ShortcutStroke(key: "r", command: true)
        ))
        #expect(reopenedBindings[ShortcutAction.renameTab.rawValue] == .unbound)
        #expect(reopenedBindings[ShortcutAction.focusLeft.rawValue] == focusLeft)
    }

    @Test func atomicWritePreservesConfigSymlink() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let targetURL = tempDir.appendingPathComponent("linked-settings.json", isDirectory: false)
        let configURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        let payload = #"{"app":{"devWindowDisplay":"Old Display"}}"#
        try Data(payload.utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            atPath: configURL.path,
            withDestinationPath: targetURL.lastPathComponent
        )

        let store = JSONConfigStore(fileURL: configURL)
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        try await store.set("New Display", for: key)

        let linkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: configURL.path)
        #expect(linkDestination == targetURL.lastPathComponent)
        let targetRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: targetURL)) as? [String: Any]
        let targetApp = targetRoot?["app"] as? [String: Any]
        #expect(targetApp?["devWindowDisplay"] as? String == "New Display")
    }
}

private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        for await result in group {
            if let result {
                group.cancelAll()
                return result
            }
        }
        fatalError("timed out without producing a value")
    }
}
