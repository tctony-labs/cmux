import CmuxProcess
import Foundation
import Testing

@testable import CmuxCommandPalette

@MainActor
@Suite struct CommandPaletteQuickRunModelTests {
    @Test func projectsOutputAndCompletion() async {
        let runner = QuickRunFakeRunner(events: [
            .output(Data("hello".utf8)),
            .output(Data(" world".utf8)),
            .finished(exitStatus: 3),
        ])
        let model = CommandPaletteQuickRunModel(runner: runner)

        model.start(command: "example", shell: "/bin/zsh", directory: "/tmp")
        await model.waitForCurrentRun()

        #expect(model.command == "example")
        #expect(model.directory == "/tmp")
        #expect(model.output == "hello world")
        #expect(model.state == .finished(exitStatus: 3))
    }

    @Test func capsRetainedOutput() async {
        let runner = QuickRunFakeRunner(events: [
            .output(Data("123456789".utf8)),
            .finished(exitStatus: 0),
        ])
        let model = CommandPaletteQuickRunModel(runner: runner, maximumOutputBytes: 5)

        model.start(command: "example", shell: "/bin/zsh", directory: "/tmp")
        await model.waitForCurrentRun()

        #expect(model.output == "56789")
        #expect(model.isOutputTruncated)
    }

    @Test func cancellationKeepsOutputVisible() async {
        let runner = QuickRunFakeRunner(events: [.output(Data("partial".utf8))])
        let model = CommandPaletteQuickRunModel(runner: runner)

        model.start(command: "example", shell: "/bin/zsh", directory: "/tmp")
        await model.waitForCurrentRun()
        await model.cancel()

        #expect(model.output == "partial")
        #expect(model.state == .cancelled)
        let cancelCount = await runner.cancelCount
        #expect(cancelCount == 1)
    }
}

private actor QuickRunFakeRunner: StreamingCommandRunning {
    let events: [StreamingCommandEvent]
    private(set) var cancelCount = 0

    init(events: [StreamingCommandEvent]) {
        self.events = events
    }

    func run(
        command: String,
        shell: String,
        directory: String
    ) async -> AsyncStream<StreamingCommandEvent> {
        AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func cancel() async {
        cancelCount += 1
    }
}
