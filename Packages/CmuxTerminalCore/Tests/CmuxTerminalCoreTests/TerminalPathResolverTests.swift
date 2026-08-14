import Foundation
import Testing
import CmuxTerminalCore

private func existsIn(_ existingPaths: Set<String>) -> @Sendable (String) -> Bool {
    { path in existingPaths.contains((path as NSString).standardizingPath) }
}

@Suite struct TerminalPathTrailingPunctuationTests {
    @Test func trimsTrailingPeriodAfterMarkdownFile() {
        #expect(
            "~/ClaudeCode/feature-spec-template.md.".trimmingTrailingTerminalPunctuation()
                == "~/ClaudeCode/feature-spec-template.md"
        )
    }

    @Test func trimsTrailingCommaInList() {
        #expect(
            "/tmp/fixtures/first.txt,".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/first.txt"
        )
    }

    @Test func trimsTrailingCloseParenWhenNoBalancedOpenParen() {
        #expect(
            "/tmp/fixtures/notes.txt)".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/notes.txt"
        )
    }

    @Test func preservesBalancedParensInMiddleOfPath() {
        #expect(
            "/tmp/fixtures/report (draft)/notes.txt".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/report (draft)/notes.txt"
        )
    }

    @Test func stripsMultipleTrailingPunctuationCharacters() {
        #expect(
            "/tmp/fixtures/report (draft).md).,!?\"".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/report (draft).md"
        )
    }

    @Test func trimsTrailingClosingQuote() {
        #expect(
            "/tmp/fixtures/notes.txt\"".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/notes.txt"
        )
    }

    @Test func trimsTrailingCJKSentencePunctuation() {
        #expect(
            "/tmp/fixtures/notes.txt。".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/notes.txt"
        )
    }
}

@Suite struct TerminalQuicklookPathResolutionTests {
    @Test(arguments: [
        ("Sources/App.swift:23", 23, nil),
        ("Sources/App.swift:23:7", 23, 7),
        ("Sources/App.swift:25-29", 25, nil),
    ])
    func resolvesFileLocationReferences(
        rawToken: String,
        expectedLine: Int,
        expectedColumn: Int?
    ) throws {
        let existingFile = "/Users/dev/project/Sources/App.swift"
        let reference = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookFileReference(
                rawToken,
                cwd: "/Users/dev/project"
            )
        )

        #expect(reference.path == existingFile)
        #expect(reference.lineNumber == expectedLine)
        #expect(reference.columnNumber == expectedColumn)
    }

    @Test func fallsBackToStrippedPathWhenLiteralPathIsMissing() {
        let strippedPath = "/tmp/cmux-cmdclick-path.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([strippedPath])).resolveQuicklookPath(
                "\(strippedPath).",
                cwd: "/tmp"
            ) == strippedPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithDot() {
        let literalPath = "/tmp/cmux-cmdclick-literal-dot.md."
        let strippedPath = "/tmp/cmux-cmdclick-literal-dot.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([literalPath, strippedPath])).resolveQuicklookPath(
                literalPath,
                cwd: "/tmp"
            ) == literalPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithParen() {
        let literalPath = "/tmp/cmux-cmdclick-literal-paren)"
        let strippedPath = "/tmp/cmux-cmdclick-literal-paren"
        #expect(
            TerminalPathResolver(fileExists: existsIn([literalPath, strippedPath])).resolveQuicklookPath(
                literalPath,
                cwd: "/tmp"
            ) == literalPath
        )
    }

    @Test func resolvesRelativeMarkdownPathWithTrailingDot() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "docs/specs/2026-05-22-test.md.",
                cwd: cwd
            ) == existingFile
        )
    }

    @Test func resolvesRelativePathWithTrailingComma() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/src/main.swift"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "src/main.swift,",
                cwd: cwd
            ) == existingFile
        )
    }

    @Test func returnsNilForRelativePathThatDoesNotExist() {
        #expect(
            TerminalPathResolver(fileExists: existsIn([])).resolveQuicklookPath(
                "docs/nonexistent.md.",
                cwd: "/Users/dev/project"
            ) == nil
        )
    }

    @Test func relativeCandidateWithoutCwdIsSkipped() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveQuicklookPath(
                "src/main.swift",
                cwd: nil
            ) == nil
        )
    }

    @Test func unquotesShellQuotedToken() {
        let existingFile = "/tmp/cmux quicklook spaced.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "\"\(existingFile)\"",
                cwd: "/tmp"
            ) == existingFile
        )
    }

    @Test func unescapesBackslashEscapedSpaces() {
        let existingFile = "/tmp/cmux quicklook escaped.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "/tmp/cmux\\ quicklook\\ escaped.md",
                cwd: "/tmp"
            ) == existingFile
        )
    }
}

@Suite struct TerminalOpenURLFilePathTests {
    @Test func resolvesFileLineAndColumnReference() throws {
        let existingFile =
            "/Users/changtang/Develop/XiaoWei/workspace/src/xiaowei-next/worktrees/outpost/" +
            "crates/xw-core/src/bridge/hub.rs"
        let reference = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFileReference(
                "\(existingFile):75:13",
                cwd: "/Users/changtang/Develop/XiaoWei/workspace/src/xiaowei-next/worktrees/outpost"
            )
        )

        #expect(reference.path == existingFile)
        #expect(reference.lineNumber == 75)
        #expect(reference.columnNumber == 13)
    }

    @Test(arguments: ["a/rules/tony.md", "b/rules/tony.md"])
    func stripsGitDiffPrefixWhenLiteralOpenURLPathIsMissing(rawToken: String) throws {
        let existingFile = "/Users/dev/project/rules/tony.md"
        let reference = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFileReference(
                rawToken,
                cwd: "/Users/dev/project"
            )
        )

        #expect(reference.path == existingFile)
    }

    @Test func prefersLiteralPathOverStrippingGitDiffPrefix() throws {
        let literalFile = "/Users/dev/project/a/rules/tony.md"
        let strippedFile = "/Users/dev/project/rules/tony.md"
        let reference = try #require(
            TerminalPathResolver(fileExists: existsIn([literalFile, strippedFile])).resolveOpenURLFileReference(
                "a/rules/tony.md",
                cwd: "/Users/dev/project"
            )
        )

        #expect(reference.path == literalFile)
    }

    @Test func resolvesAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFilePath(
                "\(existingFile).",
                cwd: "/Users/dev/project"
            ) == existingFile
        )
    }

    @Test func resolvesQuotedAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFilePath(
                "\"\(existingFile).\"",
                cwd: "/Users/dev/project"
            ) == existingFile
        )
    }

    @Test func textWithURLSchemeIsNeverTreatedAsFilePath() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "file:///tmp/test.md",
                cwd: "/tmp"
            ) == nil
        )
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "mailto:test@example.com",
                cwd: "/tmp"
            ) == nil
        )
    }

    @Test func schemelessRelativeAndAbsoluteTextStaysEligible() {
        let relative = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([relative])).resolveOpenURLFilePath(
                "docs/specs/2026-05-22-test.md.",
                cwd: "/Users/dev/project"
            ) == relative
        )
    }
}

@Suite struct TerminalVisibleLineResolutionTests {
    @Test func visibleLinesKeepsTrailingRowsOnly() {
        let text = "one\ntwo\nthree\nfour"
        #expect(text.visibleLines(rows: 2) == ["three", "four"])
        #expect(text.visibleLines(rows: 10) == ["one", "two", "three", "four"])
    }

    @Test func visibleLinesPreservesEmptyLines() {
        #expect("a\n\nb".visibleLines(rows: 3) == ["a", "", "b"])
    }

    @Test func resolvesRawSegmentUnderColumn() throws {
        let existingFile = "/tmp/cmux-visible-line.md"
        let line = "open /tmp/cmux-visible-line.md now"
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinePath(
                line,
                column: 8,
                cwd: "/tmp"
            )
        )
        #expect(resolution.path == existingFile)
        #expect(resolution.rawToken == "/tmp/cmux-visible-line.md")
    }

    @Test func resolvesShellEscapedTokenSpanningSpaces() throws {
        let existingFile = "/tmp/cmux visible escaped.md"
        let line = "cat /tmp/cmux\\ visible\\ escaped.md"
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinePath(
                line,
                column: 6,
                cwd: "/tmp"
            )
        )
        #expect(resolution.path == existingFile)
    }

    @Test func returnsNilWhenColumnSitsOnHardDelimiter() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveVisibleLinePath(
                "a\tb",
                column: 1,
                cwd: "/tmp"
            ) == nil
        )
    }

    @Test(arguments: [
        ("--- a/rules/tony.md", 8),
        ("+++ b/rules/tony.md", 8),
    ])
    func stripsGitDiffHeaderPrefix(line: String, column: Int) throws {
        let existingFile = "/Users/dev/project/rules/tony.md"
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinePath(
                line,
                column: column,
                cwd: "/Users/dev/project"
            )
        )

        #expect(resolution.path == existingFile)
        #expect(resolution.rawToken == "rules/tony.md")
    }

    @Test(arguments: [
        (0, 40),
        (1, 4),
    ])
    func resolvesTUIHardWrappedPathFromEitherRow(row: Int, column: Int) throws {
        let cwd = "/Users/dev/project"
        let relativePath =
            ".agents/notes/implemented/architecture/" +
            "2026-07-10-single-file-executable-sdk-runtime-distribution.md"
        let existingFile = "\(cwd)/\(relativePath)"
        let lines = [
            "完整的设计取舍记录在 .agents/notes/implemented/architecture/" +
                "2026-07-10-single-file-executable-sdk-runtime-",
            "distribution.md。",
        ]
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinesPath(
                lines,
                row: row,
                column: column,
                cwd: cwd
            )
        )

        #expect(resolution.path == existingFile)
        #expect(resolution.rawToken == relativePath + "。")
    }

    @Test func resolvesHardWrappedPathAtCellColumnBeyondCharacterCount() throws {
        let cwd = "/Users/dev/project"
        let relativePath =
            ".agents/notes/implemented/architecture/" +
            "2026-07-10-single-file-executable-sdk-runtime-distribution.md"
        let existingFile = "\(cwd)/\(relativePath)"
        let firstLine =
            "完整的设计取舍记录在 .agents/notes/implemented/architecture/" +
            "2026-07-10-single-file-executable-sdk-runtime-"
        let lines = [firstLine, "distribution.md。"]
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinesPath(
                lines,
                row: 0,
                column: firstLine.count + 5,
                cwd: cwd
            )
        )

        #expect(resolution.path == existingFile)
    }
}
