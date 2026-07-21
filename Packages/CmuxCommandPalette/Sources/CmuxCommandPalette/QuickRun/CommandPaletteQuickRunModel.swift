public import CmuxProcess
import Foundation
public import Observation

/// Projects a streaming shell command into command-palette-friendly state.
@MainActor
@Observable
public final class CommandPaletteQuickRunModel {
    /// Maximum output retained by the default model.
    public static let defaultMaximumOutputBytes = 512 * 1024

    /// The command currently displayed by the popup.
    public private(set) var command = ""
    /// The working directory used for the command.
    public private(set) var directory = ""
    /// The decoded merged standard output and standard error retained so far.
    public private(set) var output = ""
    /// Whether output at the beginning of the run was discarded to enforce the limit.
    public private(set) var isOutputTruncated = false
    /// The current run state.
    public private(set) var state = CommandPaletteQuickRunState.idle

    @ObservationIgnored private let runner: any StreamingCommandRunning
    @ObservationIgnored private let maximumOutputBytes: Int
    @ObservationIgnored private var outputData = Data()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    /// Creates a quick-run model with an injected streaming runner.
    ///
    /// - Parameters:
    ///   - runner: The process boundary used to execute commands.
    ///   - maximumOutputBytes: The maximum merged output retained in memory.
    public init(
        runner: any StreamingCommandRunning,
        maximumOutputBytes: Int = CommandPaletteQuickRunModel.defaultMaximumOutputBytes
    ) {
        self.runner = runner
        self.maximumOutputBytes = max(1, maximumOutputBytes)
    }

    /// Starts a command and resets any previously displayed result.
    ///
    /// - Parameters:
    ///   - command: The shell command to execute.
    ///   - shell: The login shell executable.
    ///   - directory: The command's working directory.
    public func start(command: String, shell: String, directory: String) {
        generation &+= 1
        let runGeneration = generation
        runTask?.cancel()
        self.command = command
        self.directory = directory
        outputData.removeAll(keepingCapacity: true)
        output = ""
        isOutputTruncated = false
        state = .running

        runTask = Task { [weak self, runner] in
            let stream = await runner.run(
                command: command,
                shell: shell,
                directory: directory
            )
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self, self.generation == runGeneration else { return }
                self.apply(event)
            }
        }
    }

    /// Cancels the active command while keeping its output visible.
    public func cancel() async {
        guard state.isRunning else { return }
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        state = .cancelled
        await runner.cancel()
    }

    /// Cancels any active command and clears all displayed state.
    public func reset() {
        let shouldCancel = state.isRunning
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        command = ""
        directory = ""
        outputData.removeAll(keepingCapacity: false)
        output = ""
        isOutputTruncated = false
        state = .idle
        if shouldCancel {
            Task { [runner] in
                await runner.cancel()
            }
        }
    }

    func waitForCurrentRun() async {
        await runTask?.value
    }

    private func apply(_ event: StreamingCommandEvent) {
        switch event {
        case .output(let data):
            append(data)
        case .finished(let exitStatus):
            state = .finished(exitStatus: exitStatus)
            runTask = nil
        case .failed(let message):
            state = .failed(message: message)
            runTask = nil
        case .cancelled:
            state = .cancelled
            runTask = nil
        }
    }

    private func append(_ data: Data) {
        outputData.append(data)
        if outputData.count > maximumOutputBytes {
            outputData.removeFirst(outputData.count - maximumOutputBytes)
            isOutputTruncated = true
        }
        output = String(decoding: outputData, as: UTF8.self)
    }
}
