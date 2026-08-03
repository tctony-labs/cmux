import Foundation

struct RecentWorkspaceHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let directory: String
    let displayName: String
    let customTitle: String?
    let lastOpenedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case directory
        case displayName
        case customTitle
        case lastOpenedAt
    }

    init(
        id: UUID = UUID(),
        directory: String,
        displayName: String,
        customTitle: String? = nil,
        lastOpenedAt: Date
    ) {
        self.id = id
        self.directory = directory
        self.displayName = displayName
        self.customTitle = customTitle
        self.lastOpenedAt = lastOpenedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        directory = try container.decode(String.self, forKey: .directory)
        displayName = try container.decode(String.self, forKey: .displayName)
        if container.contains(.customTitle) {
            customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        } else {
            customTitle = displayName
        }
        lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(directory, forKey: .directory)
        try container.encode(displayName, forKey: .displayName)
        if let customTitle {
            try container.encode(customTitle, forKey: .customTitle)
        } else {
            try container.encodeNil(forKey: .customTitle)
        }
        try container.encode(lastOpenedAt, forKey: .lastOpenedAt)
    }

    static func normalizedDirectory(_ directory: String) -> String? {
        let expanded = NSString(string: directory)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    static func displayDirectory(
        _ directory: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        guard let normalizedDirectory = Self.normalizedDirectory(directory),
              let normalizedHome = Self.normalizedDirectory(homeDirectory) else {
            return directory
        }
        if normalizedDirectory == normalizedHome {
            return "~"
        }
        let homePrefix = normalizedHome + "/"
        guard normalizedDirectory.hasPrefix(homePrefix) else {
            return normalizedDirectory
        }
        return "~/" + normalizedDirectory.dropFirst(homePrefix.count)
    }

    var displayDirectory: String {
        Self.displayDirectory(directory)
    }

    var menuTitle: String {
        let opened = String(
            format: String(
                localized: "menu.history.recentWorkspaces.openedAtFormat",
                defaultValue: "Opened %@"
            ),
            lastOpenedAt.formatted(date: .abbreviated, time: .shortened)
        )
        return HistoryMenuLineFormatter.titleWithSubtitle(
            title: displayName,
            subtitle: "\(displayDirectory), \(opened)"
        )
    }
}
