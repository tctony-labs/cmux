/// The lifecycle state of a command-palette quick run.
public enum CommandPaletteQuickRunState: Sendable, Equatable {
    /// No command is active or displayed.
    case idle
    /// The command is running and may emit more output.
    case running
    /// The command exited with the supplied process status.
    case finished(exitStatus: Int32)
    /// The command could not be launched.
    case failed(message: String)
    /// The user cancelled the command.
    case cancelled

    /// Whether the command is still running.
    public var isRunning: Bool {
        self == .running
    }
}
