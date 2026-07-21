public import Foundation

/// One event emitted while a streaming command runs.
public enum StreamingCommandEvent: Sendable, Equatable {
    /// A chunk read from the command's merged standard output and standard error.
    case output(Data)
    /// The command exited with the supplied process status.
    case finished(exitStatus: Int32)
    /// The command could not be launched.
    case failed(message: String)
    /// The command was cancelled by its caller.
    case cancelled
}
