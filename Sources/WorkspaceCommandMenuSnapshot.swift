import Foundation

/// Immutable state rendered by the File > Workspace submenu.
struct WorkspaceCommandMenuSnapshot: Equatable {
    struct WindowMoveTarget: Equatable, Identifiable {
        let id: UUID
        let label: String
        let isCurrentWindow: Bool
    }

    let hasSelectedWorkspace: Bool
    let hasCustomTitle: Bool
    let workspaceIndex: Int?
    let workspaceCount: Int
    let pinMenuLabel: String
    let canPin: Bool
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let windowMoveTargets: [WindowMoveTarget]
}
