public import Foundation

/// Resolves file-system paths out of raw terminal text.
///
/// This is the shared path heuristics layer behind cmd-click QuickLook,
/// "open file at cursor", and terminal link opening. Candidate spellings come
/// from the pure `String` transforms in this domain (shell-token unquoting
/// and unescaping, trailing-punctuation trimming, visible-line
/// tokenization); the resolver expands them for `~`, resolves relative
/// candidates against the surface cwd, standardizes, and probes in order.
///
/// The resolver is an instantiated value because resolution is pure only up
/// to the file system: every resolve probes candidates for existence, so the
/// file-existence capability is injected at init. Production uses the real
/// file system; tests inject a fake probe. This mirrors
/// ``TerminalLinkRouter``'s injected `BrowserHostNormalizing` seam.
public struct TerminalPathResolver: Sendable {
    private let fileExists: @Sendable (String) -> Bool

    /// Creates a resolver that probes candidate paths through `fileExists`.
    ///
    /// - Parameter fileExists: The file-existence capability; defaults to the
    ///   real file system.
    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.fileExists = fileExists
    }

    /// Resolves raw terminal text to an existing file path for QuickLook.
    ///
    /// Candidates are derived from the raw text (as-is, shell-unescaped,
    /// shell-unquoted, and trailing-punctuation-trimmed variants), expanded
    /// for `~`, resolved against `cwd` when relative, standardized, and probed
    /// in order. The first existing path wins.
    ///
    /// - Parameters:
    ///   - rawText: The raw text under the cursor or selection.
    ///   - cwd: The surface's working directory used for relative candidates.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveQuicklookPath(_ rawText: String, cwd: String?) -> String? {
        resolveQuicklookFileReference(rawText, cwd: cwd)?.path
    }

    /// Resolves raw terminal text to an existing path and optional source
    /// location.
    ///
    /// A trailing `:line`, `:line:column`, or `:start-end` suffix is treated
    /// as terminal location metadata when the path before it exists. The first
    /// line of a range is returned.
    ///
    /// - Parameters:
    ///   - rawText: The raw text under the cursor or selection.
    ///   - cwd: The surface's working directory used for relative candidates.
    /// - Returns: The first existing path and its optional location, or `nil`.
    public func resolveQuicklookFileReference(
        _ rawText: String,
        cwd: String?
    ) -> (path: String, lineNumber: Int?, columnNumber: Int?)? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var seenPaths: Set<String> = []
        for token in trimmed.pathResolutionCandidates() {
            var references: [(pathToken: String, lineNumber: Int?, columnNumber: Int?)] = []
            if let locationReference = token.terminalFileLocationReference() {
                references.append(
                    (
                        locationReference.pathToken,
                        locationReference.lineNumber,
                        locationReference.columnNumber
                    )
                )
            }
            references.append((token, nil, nil))

            for reference in references {
                let normalizedToken = reference.pathToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedToken.isEmpty else { continue }

                let expandedToken = (normalizedToken as NSString).expandingTildeInPath
                let candidatePath: String
                if expandedToken.hasPrefix("/") {
                    candidatePath = expandedToken
                } else {
                    guard let cwd, !cwd.isEmpty else { continue }
                    candidatePath = (cwd as NSString).appendingPathComponent(expandedToken)
                }

                let standardizedPath = (candidatePath as NSString).standardizingPath
                guard seenPaths.insert(standardizedPath).inserted else { continue }
                if fileExists(standardizedPath) {
                    return (standardizedPath, reference.lineNumber, reference.columnNumber)
                }
            }
        }

        return nil
    }

    /// Resolves the path token under a column of a visible terminal line.
    ///
    /// Tries the raw whitespace-delimited segment around the column first,
    /// then the shell-escape-aware token, and resolves each through
    /// ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the cursor.
    ///   - cwd: The surface's working directory.
    /// - Returns: The raw token plus its resolved path, or `nil`.
    public func resolveVisibleLinePath(
        _ line: String,
        column: Int,
        cwd: String
    ) -> (rawToken: String, path: String, lineNumber: Int?, columnNumber: Int?)? {
        if let rawToken = line.gitDiffPathToken(containingColumn: column),
           let reference = resolveQuicklookFileReference(rawToken, cwd: cwd) {
            return (rawToken, reference.path, reference.lineNumber, reference.columnNumber)
        }

        for rawToken in line.pathTokenCandidates(containingColumn: column) {
            if let reference = resolveQuicklookFileReference(rawToken, cwd: cwd) {
                return (rawToken, reference.path, reference.lineNumber, reference.columnNumber)
            }
        }
        return nil
    }

    /// Resolves a path under a visible terminal cell, including a path split
    /// across a pair of adjacent hard rows by a full-screen terminal UI.
    ///
    /// Normal terminal soft wraps are already unwrapped by Ghostty. Some TUIs
    /// redraw wrapped content as independent hard rows, however, so neither
    /// fragment exists on disk by itself. This method first applies the usual
    /// single-row rules, then joins only tokens that touch the adjoining row
    /// edges and accepts the result only when the combined path exists.
    ///
    /// - Parameters:
    ///   - lines: The terminal rows currently visible in the viewport.
    ///   - row: The zero-based row under the cursor.
    ///   - column: The zero-based column under the cursor.
    ///   - cwd: The surface's working directory.
    /// - Returns: The raw token plus its resolved path, or `nil`.
    public func resolveVisibleLinesPath(
        _ lines: [String],
        row: Int,
        column: Int,
        cwd: String
    ) -> (rawToken: String, path: String, lineNumber: Int?, columnNumber: Int?)? {
        guard lines.indices.contains(row) else { return nil }

        let line = lines[row]
        if let resolution = resolveVisibleLinePath(line, column: column, cwd: cwd) {
            return resolution
        }

        let clickedTokens = line.pathTokenCandidates(containingColumn: column)
        guard !clickedTokens.isEmpty else { return nil }

        if row > lines.startIndex {
            let leadingTokens = line.leadingPathTokenCandidates()
            let previousTokens = lines[row - 1].trailingPathTokenCandidates()
            if let resolution = resolveJoinedVisiblePath(
                leftTokens: previousTokens,
                rightTokens: clickedTokens.filter(leadingTokens.contains),
                cwd: cwd
            ) {
                return resolution
            }
        }

        if row < lines.index(before: lines.endIndex) {
            let trailingTokens = line.trailingPathTokenCandidates()
            let nextTokens = lines[row + 1].leadingPathTokenCandidates()
            if let resolution = resolveJoinedVisiblePath(
                leftTokens: clickedTokens.filter(trailingTokens.contains),
                rightTokens: nextTokens,
                cwd: cwd
            ) {
                return resolution
            }
        }

        return nil
    }

    private func resolveJoinedVisiblePath(
        leftTokens: [String],
        rightTokens: [String],
        cwd: String
    ) -> (rawToken: String, path: String, lineNumber: Int?, columnNumber: Int?)? {
        for leftToken in leftTokens {
            for rightToken in rightTokens {
                let rawToken = leftToken + rightToken
                guard let reference = resolveQuicklookFileReference(rawToken, cwd: cwd) else {
                    continue
                }
                return (rawToken, reference.path, reference.lineNumber, reference.columnNumber)
            }
        }
        return nil
    }

    /// Resolves an open-URL request payload to an existing file path.
    ///
    /// Text that parses as a URL with a scheme is never treated as a file
    /// path; everything else goes through ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveOpenURLFilePath(_ rawText: String, cwd: String?) -> String? {
        resolveOpenURLFileReference(rawText, cwd: cwd)?.path
    }

    /// Resolves an open-URL payload to an existing file reference.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    /// - Returns: The existing path and optional source location, or `nil`.
    public func resolveOpenURLFileReference(
        _ rawText: String,
        cwd: String?
    ) -> (path: String, lineNumber: Int?, columnNumber: Int?)? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard URL(string: trimmed)?.scheme == nil else { return nil }
        if let reference = resolveQuicklookFileReference(trimmed, cwd: cwd) {
            return reference
        }

        guard trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") else { return nil }
        return resolveQuicklookFileReference(String(trimmed.dropFirst(2)), cwd: cwd)
    }
}
