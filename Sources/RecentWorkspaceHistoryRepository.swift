import Foundation
import OSLog

actor RecentWorkspaceHistoryRepository {
    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "RecentWorkspaceHistory"
    )

    private let fileURL: URL?
    // FileManager is thread-safe, and all uses remain isolated to this repository actor.
    private nonisolated(unsafe) let fileManager: FileManager
    private let homeDirectory: String?
    private var entries: [RecentWorkspaceHistoryEntry] = []
    private var revision: UInt64 = 0
    private var isLoaded = false

    init(fileURL: URL?, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.homeDirectory = RecentWorkspaceHistoryEntry.normalizedDirectory(
            fileManager.homeDirectoryForCurrentUser.path
        )
    }

    func snapshot() -> (revision: UInt64, entries: [RecentWorkspaceHistoryEntry]) {
        loadIfNeeded()
        return (revision, entries)
    }

    func recordOpened(
        directory: String,
        displayName: String,
        customTitle: String? = nil,
        openedAt: Date
    ) -> (revision: UInt64, entries: [RecentWorkspaceHistoryEntry]) {
        loadIfNeeded()
        guard let normalizedDirectory = RecentWorkspaceHistoryEntry.normalizedDirectory(directory),
              normalizedDirectory != homeDirectory else {
            return (revision, entries)
        }

        let normalizedDisplayName = normalizedDisplayName(
            displayName,
            directory: normalizedDirectory
        )
        if let index = entries.firstIndex(where: { $0.directory == normalizedDirectory }) {
            let existing = entries[index]
            guard openedAt >= existing.lastOpenedAt else {
                return (revision, entries)
            }
            entries[index] = RecentWorkspaceHistoryEntry(
                id: existing.id,
                directory: normalizedDirectory,
                displayName: normalizedDisplayName,
                customTitle: normalizedCustomTitle(customTitle),
                lastOpenedAt: openedAt
            )
        } else {
            entries.append(RecentWorkspaceHistoryEntry(
                directory: normalizedDirectory,
                displayName: normalizedDisplayName,
                customTitle: normalizedCustomTitle(customTitle),
                lastOpenedAt: openedAt
            ))
        }

        sortEntries()
        revision &+= 1
        persist()
        return (revision, entries)
    }

    func updateTitle(
        directory: String,
        displayName: String,
        customTitle: String?
    ) -> (revision: UInt64, entries: [RecentWorkspaceHistoryEntry]) {
        loadIfNeeded()
        guard let normalizedDirectory = RecentWorkspaceHistoryEntry.normalizedDirectory(directory),
              normalizedDirectory != homeDirectory,
              let index = entries.firstIndex(where: { $0.directory == normalizedDirectory }) else {
            return (revision, entries)
        }

        let existing = entries[index]
        let updated = RecentWorkspaceHistoryEntry(
            id: existing.id,
            directory: normalizedDirectory,
            displayName: normalizedDisplayName(displayName, directory: normalizedDirectory),
            customTitle: normalizedCustomTitle(customTitle),
            lastOpenedAt: existing.lastOpenedAt
        )
        guard updated != existing else { return (revision, entries) }
        entries[index] = updated
        revision &+= 1
        persist()
        return (revision, entries)
    }

    func remove(id: UUID) -> (revision: UInt64, entries: [RecentWorkspaceHistoryEntry]) {
        loadIfNeeded()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return (revision, entries)
        }
        entries.remove(at: index)
        revision &+= 1
        persist()
        return (revision, entries)
    }

    nonisolated static func defaultHistoryFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests else { return nil }
        let resolvedAppSupport = appSupportDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        guard let resolvedAppSupport else { return nil }

        let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleId = bundleId.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app"
        let safeBundleId = resolvedBundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(
                "workspace-history-\(safeBundleId).json",
                isDirectory: false
            )
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(
                  RecentWorkspaceHistoryPersistenceSnapshot.self,
                  from: data
              ),
              snapshot.version == RecentWorkspaceHistoryPersistenceSnapshot.currentVersion else {
            return
        }

        var newestEntryByDirectory: [String: RecentWorkspaceHistoryEntry] = [:]
        var removedHomeDirectoryEntry = false
        for entry in snapshot.entries {
            guard let directory = RecentWorkspaceHistoryEntry.normalizedDirectory(entry.directory) else {
                continue
            }
            guard directory != homeDirectory else {
                removedHomeDirectoryEntry = true
                continue
            }
            let normalizedEntry = RecentWorkspaceHistoryEntry(
                id: entry.id,
                directory: directory,
                displayName: normalizedDisplayName(entry.displayName, directory: directory),
                customTitle: normalizedCustomTitle(entry.customTitle),
                lastOpenedAt: entry.lastOpenedAt
            )
            if let existing = newestEntryByDirectory[directory],
               existing.lastOpenedAt > normalizedEntry.lastOpenedAt {
                continue
            }
            newestEntryByDirectory[directory] = normalizedEntry
        }
        entries = Array(newestEntryByDirectory.values)
        sortEntries()
        if !entries.isEmpty {
            revision &+= 1
        }
        if removedHomeDirectoryEntry {
            persist()
        }
    }

    private func normalizedDisplayName(_ displayName: String, directory: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let fallback = URL(fileURLWithPath: directory, isDirectory: true).lastPathComponent
        return fallback.isEmpty ? directory : fallback
    }

    private func normalizedCustomTitle(_ customTitle: String?) -> String? {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sortEntries() {
        entries.sort { lhs, rhs in
            if lhs.lastOpenedAt != rhs.lastOpenedAt {
                return lhs.lastOpenedAt > rhs.lastOpenedAt
            }
            return lhs.directory.localizedCaseInsensitiveCompare(rhs.directory) == .orderedAscending
        }
    }

    private func persist() {
        guard let fileURL else { return }
        guard !entries.isEmpty else {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                if fileManager.fileExists(atPath: fileURL.path) {
                    let path = fileURL.path
                    let message = error.localizedDescription
                    let logMessage = "recentWorkspaceHistory.remove.failed file=\(path) error=\(message)"
                    Self.logger.debug("\(logMessage, privacy: .public)")
                }
            }
            return
        }

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let snapshot = RecentWorkspaceHistoryPersistenceSnapshot(entries: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            let path = fileURL.path
            let entryCount = entries.count
            let message = error.localizedDescription
            let logMessage = "recentWorkspaceHistory.save.failed file=\(path) entries=\(entryCount) error=\(message)"
            Self.logger.debug("\(logMessage, privacy: .public)")
        }
    }
}
