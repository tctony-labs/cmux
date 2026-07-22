public import Foundation
public import CmuxSettings
public import CmuxTestSupport

/// Opens files in the user's preferred editor, falling back to the system
/// default handler — the launch path lifted from the legacy
/// `PreferredEditorSettings.open`.
///
/// Behavior, kept faithful to the legacy namespace:
/// 1. When a UI-test capture file is configured under
///    `CMUX_UI_TEST_CAPTURE_OPEN_PATH`, the open is recorded there and
///    intercepted (no process or system open).
/// 2. With no configured editor command, the file opens with the system
///    default handler.
/// 3. Otherwise `/bin/sh -c "<command> '<path>'"` is spawned with silenced
///    stdio; a launch failure or a nonzero exit (e.g. command-not-found
///    exiting 127) falls back to the system default handler.
///
/// Isolation: `@MainActor`, because every caller is a main-thread UI flow
/// and the legacy code spawned the editor process synchronously on the
/// calling (main) thread; co-locating keeps the spawn timing identical.
/// Exit status is observed via `Process.terminationHandler` (replacing the
/// legacy `DispatchQueue.global` + `waitUntilExit` hop); the handler hops
/// back to the main actor for the fallback open, matching the legacy
/// `DispatchQueue.main.async` fallback.
@MainActor
public struct PreferredEditorService: FileOpening {
    private let editor: any PreferredEditorReading
    private let capture: any TestCaptureWriting
    private let systemOpener: any SystemFileOpening
    private let emacsClientExecutableURL: URL
    private let emacsClientArgumentsPrefix: [String]

    /// Creates a service with explicit collaborators (tests pass fakes).
    ///
    /// - Parameters:
    ///   - editor: Source of the configured editor command.
    ///   - capture: UI-test capture seam consulted before any real open.
    ///   - systemOpener: Fallback opener for the no-command and
    ///     failed-command paths.
    ///   - emacsClientExecutableURL: Executable used for line-aware Emacs opens.
    ///   - emacsClientArgumentsPrefix: Arguments placed before `--eval`.
    public init(
        editor: any PreferredEditorReading,
        capture: any TestCaptureWriting,
        systemOpener: any SystemFileOpening,
        emacsClientExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        emacsClientArgumentsPrefix: [String] = ["emacsclient"]
    ) {
        self.editor = editor
        self.capture = capture
        self.systemOpener = systemOpener
        self.emacsClientExecutableURL = emacsClientExecutableURL
        self.emacsClientArgumentsPrefix = emacsClientArgumentsPrefix
    }

    /// Creates the production service: editor command from `defaults`,
    /// capture from the process environment, fallback through `NSWorkspace`.
    public init(defaults: UserDefaults) {
        let emacsClientLaunch = Self.emacsClientLaunch()
        self.init(
            editor: PreferredEditorSettingsStore(defaults: defaults),
            capture: UITestCaptureSink(),
            systemOpener: NSWorkspaceFileOpener(),
            emacsClientExecutableURL: emacsClientLaunch.executableURL,
            emacsClientArgumentsPrefix: emacsClientLaunch.argumentsPrefix
        )
    }

    static func emacsClientLaunch(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> (executableURL: URL, argumentsPrefix: [String]) {
        let candidates = [
            "/opt/homebrew/bin/emacsclient",
            "/usr/local/bin/emacsclient",
            "/usr/bin/emacsclient",
        ]
        if let executable = candidates.first(where: isExecutable) {
            return (URL(fileURLWithPath: executable), [])
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["emacsclient"])
    }

    public func open(_ url: URL) {
        if capture.appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_PATH",
            line: url.path
        ) {
            return
        }

        guard let command = editor.resolvedCommand else {
            systemOpener.openWithSystemDefault(url)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(url.path.posixShellSingleQuoted)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let systemOpener = self.systemOpener
        process.terminationHandler = { @Sendable process in
            // Fall back when the command fails (e.g. command not found exits
            // 127 but /bin/sh itself launched fine).
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in
                systemOpener.openWithSystemDefault(url)
            }
        }

        do {
            try process.run()
        } catch {
            systemOpener.openWithSystemDefault(url)
        }
    }

    /// Opens a file at a source location through the user's Emacs client.
    ///
    /// - Parameters:
    ///   - url: The file to visit.
    ///   - lineNumber: The one-based source line to reveal.
    ///   - columnNumber: The optional one-based source column to reveal.
    public func openInEmacs(_ url: URL, lineNumber: Int, columnNumber: Int? = nil) {
        if capture.appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_PATH",
            line: url.path
        ) {
            return
        }

        let escapedPath = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let openLineExpression =
            "(tctony/persp-view-file-line-external \"\(escapedPath)\" \(lineNumber))"
        let expression: String
        if let columnNumber {
            expression = "(progn \(openLineExpression) (move-to-column \(columnNumber - 1)))"
        } else {
            expression = openLineExpression
        }
        let process = Process()
        process.executableURL = emacsClientExecutableURL
        process.arguments = emacsClientArgumentsPrefix + ["--eval", expression]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let systemOpener = self.systemOpener
        process.terminationHandler = { @Sendable process in
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in
                systemOpener.openWithSystemDefault(url)
            }
        }

        do {
            try process.run()
        } catch {
            systemOpener.openWithSystemDefault(url)
        }
    }
}
