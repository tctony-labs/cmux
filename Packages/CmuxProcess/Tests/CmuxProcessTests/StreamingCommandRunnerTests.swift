import Foundation
import Testing

@testable import CmuxProcess

@Suite struct StreamingCommandRunnerTests {
    @Test func streamsMergedOutputAndExitStatus() async throws {
        let runner = StreamingCommandRunner()
        let stream = await runner.run(
            command: "printf stdout; printf stderr >&2; exit 7",
            shell: "/bin/zsh",
            directory: "/tmp"
        )

        var output = Data()
        var exitStatus: Int32?
        for await event in stream {
            switch event {
            case .output(let data):
                output.append(data)
            case .finished(let status):
                exitStatus = status
            case .failed(let message):
                Issue.record("Unexpected launch failure: \(message)")
            case .cancelled:
                Issue.record("Unexpected cancellation")
            }
        }

        #expect(String(decoding: output, as: UTF8.self) == "stdoutstderr")
        #expect(exitStatus == 7)
    }

    @Test func reportsLaunchFailure() async {
        let runner = StreamingCommandRunner()
        let stream = await runner.run(
            command: "echo unreachable",
            shell: "/path/that/does/not/exist",
            directory: "/tmp"
        )

        var failure: String?
        for await event in stream {
            if case .failed(let message) = event {
                failure = message
            }
        }

        #expect(failure != nil)
    }

    @Test func runsInteractiveShell() async {
        let runner = StreamingCommandRunner()
        let stream = await runner.run(
            command: "[[ -o interactive ]] && printf interactive",
            shell: "/bin/zsh",
            directory: "/tmp"
        )

        var output = Data()
        var exitStatus: Int32?
        for await event in stream {
            switch event {
            case .output(let data):
                output.append(data)
            case .finished(let status):
                exitStatus = status
            case .failed(let message):
                Issue.record("Unexpected launch failure: \(message)")
            case .cancelled:
                Issue.record("Unexpected cancellation")
            }
        }

        #expect(String(decoding: output, as: UTF8.self).contains("interactive"))
        #expect(exitStatus == 0)
    }

    @Test func cancellationEndsStream() async {
        let runner = StreamingCommandRunner()
        let stream = await runner.run(
            command: "while :; do :; done",
            shell: "/bin/zsh",
            directory: "/tmp"
        )

        await runner.cancel()
        var events: [StreamingCommandEvent] = []
        for await event in stream {
            events.append(event)
        }

        #expect(events == [.cancelled])
    }
}
