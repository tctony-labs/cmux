import Foundation

/// Runs one shell command at a time and streams its merged output.
public protocol StreamingCommandRunning: Sendable {
    /// Starts a shell command and returns its output and completion events.
    ///
    /// Starting a new command cancels any command still owned by the runner.
    ///
    /// - Parameters:
    ///   - command: The command string interpreted by `shell`.
    ///   - shell: The shell executable used in interactive login mode.
    ///   - directory: The command's working directory.
    /// - Returns: A stream that ends after one terminal event.
    func run(
        command: String,
        shell: String,
        directory: String
    ) async -> AsyncStream<StreamingCommandEvent>

    /// Cancels the command currently owned by the runner, if any.
    func cancel() async
}
