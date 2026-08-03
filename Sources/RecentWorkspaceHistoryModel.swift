import Foundation
import Observation

@MainActor
@Observable
final class RecentWorkspaceHistoryModel {
    private(set) var entries: [RecentWorkspaceHistoryEntry] = []
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private let repository: RecentWorkspaceHistoryRepository
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var operationTail: Task<Void, Never>?

    init(repository: RecentWorkspaceHistoryRepository) {
        self.repository = repository
        startTask { repository in
            await repository.snapshot()
        }
    }

    func recordOpened(
        directory: String,
        displayName: String,
        customTitle: String?,
        openedAt: Date
    ) {
        startTask { repository in
            await repository.recordOpened(
                directory: directory,
                displayName: displayName,
                customTitle: customTitle,
                openedAt: openedAt
            )
        }
    }

    func updateTitle(directory: String, displayName: String, customTitle: String?) {
        startTask { repository in
            await repository.updateTitle(
                directory: directory,
                displayName: displayName,
                customTitle: customTitle
            )
        }
    }

    func remove(id: UUID) {
        startTask { repository in
            await repository.remove(id: id)
        }
    }

    private func startTask(
        operation: @escaping @Sendable (
            RecentWorkspaceHistoryRepository
        ) async -> (revision: UInt64, entries: [RecentWorkspaceHistoryEntry])
    ) {
        let taskId = UUID()
        let precedingTask = operationTail
        let task = Task { @MainActor [weak self, repository] in
            await precedingTask?.value
            let snapshot = await operation(repository)
            guard !Task.isCancelled, let self else { return }
            if snapshot.revision >= revision {
                revision = snapshot.revision
                entries = snapshot.entries
            }
            tasks.removeValue(forKey: taskId)
        }
        tasks[taskId] = task
        operationTail = task
    }
}
