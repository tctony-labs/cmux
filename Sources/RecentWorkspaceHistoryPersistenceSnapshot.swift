struct RecentWorkspaceHistoryPersistenceSnapshot: Codable, Sendable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var entries: [RecentWorkspaceHistoryEntry]
}
