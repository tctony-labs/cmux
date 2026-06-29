import Foundation

struct SymlinkWorkspaceFixture {
    let container: URL
    let realRoot: URL
    let symlinkRoot: URL
    let sourcesDirectory: URL
    let contentView: URL

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-symlink-workspace-\(UUID().uuidString)", isDirectory: true)
        realRoot = container.appendingPathComponent("real", isDirectory: true)
        symlinkRoot = container.appendingPathComponent("linked", isDirectory: true)
        sourcesDirectory = realRoot.appendingPathComponent("Sources", isDirectory: true)
        contentView = sourcesDirectory.appendingPathComponent("ContentView.swift")

        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try "import SwiftUI\n".write(to: contentView, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: container)
    }
}
