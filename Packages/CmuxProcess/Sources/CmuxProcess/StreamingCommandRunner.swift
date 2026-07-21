import Foundation

/// Runs interactive login-shell commands and streams merged output.
public actor StreamingCommandRunner: StreamingCommandRunning {
    private var process: Process?
    private var readHandle: FileHandle?
    private var continuation: AsyncStream<StreamingCommandEvent>.Continuation?
    private var generation: UInt64 = 0
    private var didReachEndOfFile = false
    private var exitStatus: Int32?

    /// Creates an idle runner.
    public init() {}

    /// Starts `shell -l -i -c command` in `directory`.
    ///
    /// Standard output and standard error share one pipe so their relative
    /// ordering is retained as closely as the child process writes it.
    ///
    /// - Parameters:
    ///   - command: The shell command to execute.
    ///   - shell: The shell executable path.
    ///   - directory: The command's working directory.
    /// - Returns: The command's streaming events.
    public func run(
        command: String,
        shell: String,
        directory: String
    ) async -> AsyncStream<StreamingCommandEvent> {
        cancelCurrentCommand(emitCancellation: false)
        generation &+= 1
        let runGeneration = generation
        let (stream, streamContinuation) = AsyncStream<StreamingCommandEvent>.makeStream()
        continuation = streamContinuation
        didReachEndOfFile = false
        exitStatus = nil

        streamContinuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.cancelIfCurrent(generation: runGeneration)
            }
        }

        let commandProcess = Process()
        let outputPipe = Pipe()
        let outputHandle = outputPipe.fileHandleForReading
        commandProcess.executableURL = URL(fileURLWithPath: shell)
        commandProcess.arguments = ["-l", "-i", "-c", command]
        commandProcess.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        commandProcess.standardInput = FileHandle.nullDevice
        commandProcess.standardOutput = outputPipe
        commandProcess.standardError = outputPipe

        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.receiveOutput(data, generation: runGeneration)
            }
        }
        commandProcess.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task {
                await self?.receiveTermination(status, generation: runGeneration)
            }
        }

        process = commandProcess
        readHandle = outputHandle
        do {
            try commandProcess.run()
            try? outputPipe.fileHandleForWriting.close()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            finish(
                with: .failed(message: String(describing: error)),
                generation: runGeneration
            )
        }
        return stream
    }

    /// Cancels the current command and closes its output stream immediately.
    public func cancel() async {
        cancelCurrentCommand(emitCancellation: true)
    }

    private func cancelIfCurrent(generation runGeneration: UInt64) {
        guard runGeneration == generation else { return }
        cancelCurrentCommand(emitCancellation: false)
    }

    private func cancelCurrentCommand(emitCancellation: Bool) {
        let commandProcess = process
        if emitCancellation, continuation != nil {
            continuation?.yield(.cancelled)
        }
        cleanupCurrentCommand()
        if commandProcess?.isRunning == true {
            commandProcess?.terminate()
        }
    }

    private func receiveOutput(_ data: Data, generation runGeneration: UInt64) {
        guard runGeneration == generation, continuation != nil else { return }
        if data.isEmpty {
            didReachEndOfFile = true
            finishNormallyIfReady(generation: runGeneration)
            return
        }
        continuation?.yield(.output(data))
    }

    private func receiveTermination(_ status: Int32, generation runGeneration: UInt64) {
        guard runGeneration == generation, continuation != nil else { return }
        exitStatus = status
        finishNormallyIfReady(generation: runGeneration)
    }

    private func finishNormallyIfReady(generation runGeneration: UInt64) {
        guard didReachEndOfFile, let exitStatus else { return }
        finish(with: .finished(exitStatus: exitStatus), generation: runGeneration)
    }

    private func finish(
        with event: StreamingCommandEvent,
        generation runGeneration: UInt64
    ) {
        guard runGeneration == generation, let continuation else { return }
        continuation.yield(event)
        continuation.finish()
        cleanupCurrentCommand()
    }

    private func cleanupCurrentCommand() {
        readHandle?.readabilityHandler = nil
        try? readHandle?.close()
        readHandle = nil
        process?.terminationHandler = nil
        process = nil
        continuation?.finish()
        continuation = nil
        didReachEndOfFile = false
        exitStatus = nil
    }
}
