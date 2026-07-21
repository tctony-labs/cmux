import CmuxCommandPalette
import SwiftUI

struct CommandPaletteQuickRunView: View {
    let command: String
    let directory: String
    let output: String
    let isOutputTruncated: Bool
    let state: CommandPaletteQuickRunState
    let outputHeight: CGFloat
    let onCancel: () -> Void

    private let bottomAnchor = "command-palette-quick-run-bottom"

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "! \(command)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(directory)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Text(displayOutput)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(output.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                }
                .onChange(of: output) { _, _ in
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .frame(height: outputHeight)

            Divider()

            HStack(spacing: 10) {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                Spacer()
                if state.isRunning {
                    Button(
                        String(localized: "commandPalette.quickRun.stop", defaultValue: "Stop"),
                        action: onCancel
                    )
                    .buttonStyle(.borderless)
                }
                Text(
                    String(
                        localized: "commandPalette.quickRun.closeHint",
                        defaultValue: "⌘W to close"
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private var displayOutput: String {
        if output.isEmpty {
            return state.isRunning
                ? String(localized: "commandPalette.quickRun.waitingForOutput", defaultValue: "Running…")
                : String(localized: "commandPalette.quickRun.noOutput", defaultValue: "No output")
        }
        guard isOutputTruncated else { return output }
        let notice = String(
            localized: "commandPalette.quickRun.outputTruncated",
            defaultValue: "Earlier output was truncated."
        )
        return notice + "\n\n" + output
    }

    private var statusText: String {
        switch state {
        case .idle:
            return ""
        case .running:
            return String(localized: "commandPalette.quickRun.running", defaultValue: "Running")
        case .finished(let exitStatus):
            let format = String(
                localized: "commandPalette.quickRun.exitStatus",
                defaultValue: "Exited with status %lld"
            )
            return String(format: format, Int64(exitStatus))
        case .failed(let message):
            let format = String(
                localized: "commandPalette.quickRun.failed",
                defaultValue: "Failed: %@"
            )
            return String(format: format, message)
        case .cancelled:
            return String(localized: "commandPalette.quickRun.cancelled", defaultValue: "Cancelled")
        }
    }

    private var statusColor: Color {
        switch state {
        case .finished(let exitStatus):
            return exitStatus == 0 ? .secondary : .red
        case .failed:
            return .red
        default:
            return .secondary
        }
    }
}
