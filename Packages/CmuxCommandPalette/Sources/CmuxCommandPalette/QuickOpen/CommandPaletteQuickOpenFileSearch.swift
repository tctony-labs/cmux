public import Foundation
import UniformTypeIdentifiers

/// Search and path-resolution helpers for the command palette Quick Open mode.
public struct CommandPaletteQuickOpenFileSearch: Sendable {
    /// Resolved directory/search state for a Quick Open query.
    public typealias ResolvedPath = (currentDir: String, searchTerm: String, isPathMode: Bool)

    /// Creates a Quick Open helper value.
    public init() {}

    /// Extracts the filename search term from a path-oriented query.
    public static func matchingTerm(
        _ matchingQuery: String,
        workspaceRoot: String? = nil
    ) -> String {
        let trimmed = matchingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("~") || trimmed.hasPrefix("/") || trimmed.hasPrefix("./") {
            if let lastSlash = trimmed.lastIndex(of: "/") {
                let term = String(trimmed[trimmed.index(after: lastSlash)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.hasSuffix("/") {
                    let expanded: String
                    if trimmed.hasPrefix("~") {
                        expanded = NSHomeDirectory() + String(trimmed.dropFirst())
                    } else if trimmed.hasPrefix("./") {
                        let relative = String(trimmed.dropFirst(2))
                        let trimmedRoot = workspaceRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let base: String
                        if let trimmedRoot, !trimmedRoot.isEmpty {
                            base = trimmedRoot
                        } else {
                            base = FileManager.default.currentDirectoryPath
                        }
                        expanded = relative.isEmpty ? base : base + "/" + relative
                    } else {
                        expanded = trimmed
                    }
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
                       isDir.boolValue {
                        return ""
                    }
                }
                return term
            }
            return ""
        }
        return trimmed
    }

    /// Returns a stable process-local fingerprint for a query.
    public static func fingerprint(query: String) -> Int {
        var hasher = Hasher()
        hasher.combine(query)
        return hasher.finalize()
    }

    /// Returns the deduplication fingerprint for cross-directory file search.
    public static func crossDirectoryDedupFingerprint(
        query: String,
        workspaceRoot: String? = nil
    ) -> Int {
        var hasher = Hasher()
        hasher.combine("cross-directory")
        hasher.combine(query)
        hasher.combine(workspaceRoot ?? "")
        return hasher.finalize()
    }

    /// Resolves a matching query into the directory to list and search mode.
    public static func resolve(
        matchingQuery: String,
        workspaceRoot: String?
    ) -> ResolvedPath {
        guard let root = workspaceRoot, !root.isEmpty else {
            return (NSHomeDirectory(), "", true)
        }

        let trimmed = matchingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (root, "", true)
        }

        if trimmed.hasPrefix("~") || trimmed.hasPrefix("/") {
            let expanded: String
            if trimmed.hasPrefix("~") {
                expanded = NSHomeDirectory() + String(trimmed.dropFirst())
            } else {
                expanded = trimmed
            }
            let (existingDir, remainder) = resolveLongestExistingDirectory(expanded)
            return (existingDir ?? root, remainder, true)
        }

        if trimmed.hasPrefix("./") {
            let relative = String(trimmed.dropFirst(2))
            let expanded = relative.isEmpty ? root : root + "/" + relative
            let (existingDir, remainder) = resolveLongestExistingDirectory(expanded)
            return (existingDir ?? root, remainder, true)
        }

        return (root, trimmed, false)
    }

    /// Resolves the deepest existing directory prefix and unmatched remainder.
    public static func resolveLongestExistingDirectory(_ path: String) -> (existingDir: String?, remainder: String) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let fileManager = FileManager.default
        var bestDir: String?
        var bestEnd = 0
        for end in stride(from: components.count, through: 1, by: -1) {
            let candidate = components[0..<end].joined(separator: "/")
            let resolved = candidate.isEmpty ? "/" : candidate
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
                bestDir = resolved
                bestEnd = end
                break
            }
        }
        let remainder = components[bestEnd...].joined(separator: "/")
        return (bestDir, remainder)
    }

    /// Formats a directory URL as a query path relative to the workspace root when possible.
    public static func pathForDirectory(
        _ url: URL,
        rootDir: String,
        usePathPrefix: Bool = true
    ) -> String {
        let homeDir = NSHomeDirectory()
        let path = url.path
        if let relative = displayPath(url: url, rootDir: rootDir) {
            if relative.isEmpty {
                return usePathPrefix ? "./" : ""
            }
            return usePathPrefix ? "./" + relative + "/" : relative + "/"
        }
        if path.hasPrefix(homeDir + "/") {
            return "~" + String(path.dropFirst(homeDir.count)) + "/"
        }
        if path == homeDir {
            return "~/"
        }
        return path + "/"
    }

    /// Computes the query path produced by selecting a directory result,
    /// preserving the current search mode.
    ///
    /// `currentMatchingTerm` is the query with the Quick Open prefix stripped.
    /// An empty term is the implicit-root state, which counts as
    /// cross-directory mode, so the `./` path-mode prefix is omitted. An
    /// explicit path-mode query (`./…`) keeps the prefix so it stays in path
    /// mode.
    public static func directorySelectionPath(
        for url: URL,
        rootDir: String,
        currentMatchingTerm: String
    ) -> String {
        let atImplicitRoot = currentMatchingTerm
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return pathForDirectory(url, rootDir: rootDir, usePathPrefix: !atImplicitRoot)
    }

    /// Computes the query path produced when Tab completes a Quick Open candidate.
    ///
    /// Directory completion preserves the existing path-mode behavior. File
    /// completion keeps the directory prefix already typed by the user, or
    /// uses the candidate's workspace-relative path for a fuzzy search.
    ///
    /// - Parameters:
    ///   - url: The candidate URL.
    ///   - rootDir: The active workspace root directory.
    ///   - currentMatchingTerm: The Quick Open query with its `@` prefix removed.
    ///   - isDirectory: Whether the candidate is a directory.
    /// - Returns: The path portion to place after the Quick Open prefix.
    public static func candidateSelectionPath(
        for url: URL,
        rootDir: String,
        currentMatchingTerm: String,
        isDirectory: Bool
    ) -> String {
        if isDirectory {
            return directorySelectionPath(
                for: url,
                rootDir: rootDir,
                currentMatchingTerm: currentMatchingTerm
            )
        }
        if let slashIndex = currentMatchingTerm.lastIndex(of: "/") {
            return String(currentMatchingTerm[...slashIndex]) + url.lastPathComponent
        }
        return displayPath(url: url, rootDir: rootDir) ?? url.path
    }

    /// Classifies how Quick Open should open a file URL.
    public static func openAction(for url: URL) -> CommandPaletteQuickOpenFileOpenAction {
        let resolvedURL = url.resolvingSymlinksInPath()
        let utType = UTType(filenameExtension: resolvedURL.pathExtension)
        let resourceValues = try? resolvedURL.resourceValues(
            forKeys: [.isExecutableKey, .isSymbolicLinkKey]
        )
        let isExecutable = resourceValues?.isExecutable ?? false

        let isScript: Bool = {
            guard let utType else { return false }
            return utType.conforms(to: .shellScript)
                || utType.conforms(to: .pythonScript)
                || utType.conforms(to: .rubyScript)
                || utType.conforms(to: .perlScript)
                || utType.conforms(to: .phpScript)
                || utType.conforms(to: .script)
        }()

        let isKnownBinary: Bool = {
            guard let utType else { return false }
            return utType.conforms(to: .executable) || utType.conforms(to: .unixExecutable)
        }()

        if isScript {
            return .textEditor(resolvedURL)
        }

        if isKnownBinary {
            return .reveal(resolvedURL)
        }

        if isExecutable && utType == nil {
            return isTextFile(at: resolvedURL) ? .textEditor(resolvedURL) : .reveal(resolvedURL)
        }

        if utType == nil, isTextFile(at: resolvedURL) {
            return .textEditor(resolvedURL)
        }

        return .open(resolvedURL)
    }

    /// Returns whether a URL currently resolves to a directory.
    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// Lists files in a directory, sorted with directories first.
    public static func listFiles(inDirectory dir: String, maxCount: Int) -> [URL] {
        let directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        guard let contents = try? contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }
        let sorted = contents.sorted { a, b in
            let aIsDir = isDirectory(a)
            let bIsDir = isDirectory(b)
            if aIsDir != bIsDir { return aIsDir }
            return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }
        return Array(sorted.prefix(maxCount))
    }

    /// Returns whether a directory should be skipped during recursive Quick Open search.
    public static func shouldSkipDirectory(_ name: String) -> Bool {
        switch name {
        case ".git", "node_modules", "bower_components",
             "vendor", "Pods", "Carthage",
             "DerivedData", ".build", ".swiftpm",
             "target", "build", "dist",
             ".next", ".nuxt", ".dart_tool",
             ".cache", ".tox", ".eggs",
             "__pycache__", ".pytest_cache", ".mypy_cache",
             ".ruff_cache", ".turbo", ".nx",
             ".parcel-cache", ".svelte-kit", ".vercel",
             ".output", "coverage", ".nyc_output",
             ".venv", "venv", ".gradle",
             ".svn", ".hg", ".idea", ".vs",
             ".yarn":
            return true
        default:
            return false
        }
    }

    /// Searches across a workspace tree and returns the top scored file matches.
    public static func searchCrossDirectory(
        query: String,
        rootDir: String
    ) async -> [CommandPaletteQuickOpenScoredFile] {
        guard !query.isEmpty else { return [] }
        let dirKeys: [URLResourceKey] = [.isDirectoryKey]
        let rootURL = URL(fileURLWithPath: rootDir, isDirectory: true)
        let ideal = fuzzyScore(query: query, candidate: query)
        let threshold = ideal.map { Int(Double($0) * fastQuitRatio) }

        guard let rootContents = try? contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: dirKeys,
            options: []
        ) else { return [] }

        var topDirs: [URL] = []
        var seenTopDirectoryPaths: Set<String> = []
        var globalHeap: [(score: Int, url: URL, depth: Int)] = []
        for url in rootContents {
            if Task.isCancelled { return [] }
            let isDir = isDirectory(url)
            if isDir, shouldSkipDirectory(url.lastPathComponent) {
                continue
            }
            if isDir {
                let canonicalPath = url.resolvingSymlinksInPath().path
                if seenTopDirectoryPaths.insert(canonicalPath).inserted {
                    topDirs.append(url)
                }
            }
            let title = searchCandidatePath(url: url, rootDir: rootDir, isDirectory: isDir)
            if let score = fuzzyScore(query: query, candidate: title), score > 0 {
                insertTopK(&globalHeap, (score, url, 0), limit: fastQuitKeepMax)
            }
        }

        await withTaskGroup(of: [(score: Int, url: URL, depth: Int)].self) { group in
            let maxConcurrentBranches = min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
            var nextDirectoryIndex = 0

            func addNextBranchIfNeeded() {
                guard !Task.isCancelled, nextDirectoryIndex < topDirs.count else { return }
                let dirURL = topDirs[nextDirectoryIndex]
                nextDirectoryIndex += 1
                group.addTask {
                    searchCrossDirectoryBranch(
                        query: query,
                        rootDir: rootDir,
                        rootDirectory: dirURL,
                        threshold: threshold
                    )
                }
            }

            for _ in 0..<min(maxConcurrentBranches, topDirs.count) {
                addNextBranchIfNeeded()
            }

            for await localHeap in group {
                if Task.isCancelled { break }
                for item in localHeap {
                    insertTopK(&globalHeap, item, limit: fastQuitKeepMax)
                }
                addNextBranchIfNeeded()
            }
        }

        globalHeap.sort { $0.score > $1.score }
        return globalHeap.map {
            CommandPaletteQuickOpenScoredFile(url: $0.url, score: $0.score, depth: $0.depth)
        }
    }

    /// Returns the fuzzy score for a cross-directory file-search candidate.
    public static func fuzzyScore(query: String, candidate: String) -> Int? {
        fuzzyMatch(query: query, candidate: candidate)?.score
    }

    /// Returns the fuzzy score and matched character indices for a candidate.
    public static func fuzzyMatch(
        query: String,
        candidate: String
    ) -> (score: Int, indices: Set<Int>)? {
        let queryChars = Array(CommandPaletteFuzzyMatcher.normalizeForSearch(query))
        let candidateChars = Array(CommandPaletteFuzzyMatcher.normalizeForSearch(candidate))
        guard !queryChars.isEmpty else { return (0, []) }
        guard queryChars.count <= candidateChars.count else { return nil }

        var searchIndex = 0
        var previousMatch = -1
        var consecutiveRun = 0
        var score = 0
        var indices: Set<Int> = []

        for queryChar in queryChars {
            var foundIndex: Int?
            while searchIndex < candidateChars.count {
                if candidateChars[searchIndex] == queryChar {
                    foundIndex = searchIndex
                    break
                }
                searchIndex += 1
            }
            guard let matchedIndex = foundIndex else { return nil }

            indices.insert(matchedIndex)
            score += 90
            if matchedIndex == 0 || candidateChars[matchedIndex - 1] == "/" {
                score += 140
            }
            if matchedIndex == previousMatch + 1 {
                consecutiveRun += 1
                score += min(200, consecutiveRun * 45)
            } else {
                consecutiveRun = 0
                score -= min(120, max(0, matchedIndex - previousMatch - 1) * 4)
            }

            previousMatch = matchedIndex
            searchIndex = matchedIndex + 1
        }

        score -= max(0, candidateChars.count - queryChars.count)
        return (max(1, score), indices)
    }

    /// Returns a lowercase path relative to the root when possible.
    public static func relativePath(url: URL, rootDir: String) -> String {
        if let displayPath = displayPath(url: url, rootDir: rootDir) {
            return displayPath.lowercased()
        }
        return url.lastPathComponent.lowercased()
    }

    /// Returns a display path relative to the root, following a symlinked root if needed.
    public static func displayPath(url: URL, rootDir: String) -> String? {
        let path = url.path
        if path.hasPrefix(rootDir + "/") {
            return String(path.dropFirst(rootDir.count + 1))
        }
        if path == rootDir {
            return ""
        }

        let resolvedPath = url.resolvingSymlinksInPath().path
        let resolvedRoot = URL(fileURLWithPath: rootDir, isDirectory: true).resolvingSymlinksInPath().path
        if resolvedPath.hasPrefix(resolvedRoot + "/") {
            return String(resolvedPath.dropFirst(resolvedRoot.count + 1))
        }
        if resolvedPath == resolvedRoot {
            return ""
        }
        return nil
    }

    /// Returns the path copied for a Quick Open result in the active search mode.
    ///
    /// - Parameters:
    ///   - url: The selected Quick Open result.
    ///   - workspaceRoot: The workspace root used by cross-directory search.
    ///   - matchingQuery: The Quick Open query with its scope prefix removed.
    /// - Returns: An absolute path for an explicit path query, or a workspace-relative path otherwise.
    public static func pathForCopying(
        _ url: URL,
        workspaceRoot: String,
        matchingQuery: String
    ) -> String {
        let trimmedQuery = matchingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.hasPrefix("~")
            || trimmedQuery.hasPrefix("/")
            || trimmedQuery.hasPrefix("./") {
            return url.path
        }
        return displayPath(url: url, rootDir: workspaceRoot) ?? url.path
    }

    private static func searchCandidatePath(url: URL, rootDir: String, isDirectory: Bool) -> String {
        let path = relativePath(url: url, rootDir: rootDir)
        return isDirectory ? path + "/" : path
    }

    private static func isTextFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else {
            return true
        }
        if data.contains(0) {
            return false
        }
        return String(data: data, encoding: .utf8) != nil
    }

    private static func contentsOfDirectory(
        at logicalDirectory: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        let resolvedDirectory = logicalDirectory.resolvingSymlinksInPath()
        let resolvedContents = try FileManager.default.contentsOfDirectory(
            at: resolvedDirectory,
            includingPropertiesForKeys: keys,
            options: options
        )
        return resolvedContents.map { resolvedURL in
            logicalDirectory.appendingPathComponent(
                resolvedURL.lastPathComponent,
                isDirectory: isDirectory(resolvedURL)
            )
        }
    }

    private static func searchCrossDirectoryBranch(
        query: String,
        rootDir: String,
        rootDirectory: URL,
        threshold: Int?
    ) -> [(score: Int, url: URL, depth: Int)] {
        let dirKeys: [URLResourceKey] = [.isDirectoryKey]
        var localHeap: [(score: Int, url: URL, depth: Int)] = []
        var scanned = 0
        var queue: [(URL, Int)] = [(rootDirectory, 1)]
        var visitedDirectoryPaths: Set<String> = [rootDirectory.resolvingSymlinksInPath().path]
        var head = 0
        while head < queue.count {
            if Task.isCancelled { return localHeap }
            let (curDir, depth) = queue[head]
            head += 1
            guard let contents = try? contentsOfDirectory(
                at: curDir,
                includingPropertiesForKeys: dirKeys,
                options: []
            ) else { continue }
            for url in contents {
                if Task.isCancelled { return localHeap }
                scanned += 1
                let isDir = isDirectory(url)
                if isDir, shouldSkipDirectory(url.lastPathComponent) { continue }
                let title = searchCandidatePath(url: url, rootDir: rootDir, isDirectory: isDir)
                if let score = fuzzyScore(query: query, candidate: title), score > 0 {
                    insertTopK(&localHeap, (score, url, depth), limit: fastQuitKeepMax)
                }
                if isDir {
                    let canonicalPath = url.resolvingSymlinksInPath().path
                    if visitedDirectoryPaths.insert(canonicalPath).inserted {
                        queue.append((url, depth + 1))
                    }
                }
            }
            if let threshold, query.count >= fastQuitMinQueryChars {
                if localHeap.count >= fastQuitKeepMax,
                   let worst = localHeap.first?.score,
                   worst >= threshold,
                   scanned >= fastQuitMinScan {
                    break
                }
            }
        }
        return localHeap
    }

    private static func insertTopK(
        _ heap: inout [(score: Int, url: URL, depth: Int)],
        _ item: (score: Int, url: URL, depth: Int),
        limit: Int
    ) {
        if heap.count < limit {
            heap.append(item)
            heap.sort { $0.score < $1.score }
        } else if let worst = heap.first?.score, item.score > worst {
            heap[0] = item
            var idx = 0
            let count = heap.count
            while true {
                let left = 2 * idx + 1
                let right = 2 * idx + 2
                var smallest = idx
                if left < count, heap[left].score < heap[smallest].score { smallest = left }
                if right < count, heap[right].score < heap[smallest].score { smallest = right }
                if smallest == idx { break }
                heap.swapAt(idx, smallest)
                idx = smallest
            }
        }
    }
}

private let fastQuitKeepMax = 30
private let fastQuitMinQueryChars = 3
private let fastQuitRatio = 0.618
private let fastQuitMinScan = 10_000
