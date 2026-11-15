import Foundation
import Logging
import SourceKitLSP

/// Manages SourceKit-LSP sessions across one pinned workspace (when `--workspace`
/// is provided) or dynamically discovered project roots (such as when running
/// globally from an Antigravity plugin).
public actor WorkspaceSessionManager {
    private static let projectMarkers = [
        "Package.swift",
        "compile_commands.json",
    ]

    private static let xcodeProjectExtensions: Set<String> = [
        "xcworkspace",
        "xcodeproj",
    ]

    private static let excludedRootNames: Set<String> = [
        "/"
    ]

    private let logger: Logger
    private let pinnedServer: SwiftLanguageServer?
    private let excludedAncestors: [URL]
    private var defaultWorkspaceRoot: URL?
    private var lastActiveWorkspaceRoot: URL?
    private var serversByRoot: [URL: SwiftLanguageServer] = [:]

    public init(pinnedLanguageServer: SwiftLanguageServer, logger: Logger) {
        self.logger = logger
        self.pinnedServer = pinnedLanguageServer
        self.excludedAncestors = Self.buildExcludedAncestors()
        self.defaultWorkspaceRoot = pinnedLanguageServer.workspaceURL
        self.lastActiveWorkspaceRoot = pinnedLanguageServer.workspaceURL
    }

    public init(
        logger: Logger,
        workspaceRoot: URL? = nil,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        additionalExcludedPaths: [String] = []
    ) {
        self.logger = logger
        let excluded = Self.buildExcludedAncestors(additionalPaths: additionalExcludedPaths)
        self.excludedAncestors = excluded

        if let workspaceRoot {
            let server = SwiftLanguageServer(logger: logger, workspaceRoot: workspaceRoot)
            self.pinnedServer = server
            self.defaultWorkspaceRoot = server.workspaceURL
            self.lastActiveWorkspaceRoot = server.workspaceURL
        } else {
            self.pinnedServer = nil
            let candidate = Self.canonicalDirectoryURL(currentDirectoryURL)
            if Self.isUsableWorkspaceRoot(candidate, excludedAncestors: excluded) {
                self.defaultWorkspaceRoot = candidate
            } else {
                self.defaultWorkspaceRoot = nil
            }
        }
    }

    /// Background-warms the pinned workspace or a valid initial project workspace.
    /// Avoids spawning SourceKit-LSP on non-project directories (like `/` or `$HOME`).
    public func warmUpDefaultIfApplicable() async {
        if let pinnedServer {
            try? await pinnedServer.initialize()
            return
        }

        guard let root = defaultWorkspaceRoot, Self.containsSwiftProjectMarkers(at: root) else {
            return
        }

        let server = server(forWorkspaceRoot: root)
        try? await server.initialize()
    }

    /// Updates the default workspace hint from MCP `initialize` parameters when
    /// running without an explicit `--workspace` argument.
    public func updateClientWorkspaceHint(from initializeParams: JSONObject?) {
        guard pinnedServer == nil, let params = initializeParams else {
            return
        }

        let candidates = Self.workspaceCandidates(from: params)
        for candidate in candidates {
            let canonical = Self.canonicalDirectoryURL(candidate)
            if Self.isUsableWorkspaceRoot(canonical, excludedAncestors: excludedAncestors) {
                defaultWorkspaceRoot = canonical
                logger.info("Updated default workspace from MCP client: \(canonical.path)")
                return
            }
        }
    }

    /// Resolves the `SwiftLanguageServer` and normalized file path for a file-scoped tool call.
    public func server(forFilePath filePath: String) -> (server: SwiftLanguageServer, resolvedPath: String) {
        let resolvedURL = resolveFileURL(filePath)

        if let pinnedServer {
            return (pinnedServer, resolvedURL.path)
        }

        let root = Self.discoverProjectRoot(
            for: resolvedURL,
            fallbackRoot: defaultWorkspaceRoot,
            excludedAncestors: excludedAncestors
        )
        let server = server(forWorkspaceRoot: root)
        lastActiveWorkspaceRoot = server.workspaceURL
        return (server, resolvedURL.path)
    }

    /// Resolves a `SwiftLanguageServer` for workspace-wide operations without a `file_path`.
    public func serverForWorkspace(explicitPath: String? = nil) throws -> SwiftLanguageServer {
        if let pinnedServer {
            return pinnedServer
        }

        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let explicitURL = resolveFileURL(explicitPath)
            var isDirectory: ObjCBool = false
            let directoryURL: URL
            if FileManager.default.fileExists(atPath: explicitURL.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                directoryURL = Self.canonicalDirectoryURL(explicitURL)
            } else {
                directoryURL = Self.discoverProjectRoot(
                    for: explicitURL,
                    fallbackRoot: defaultWorkspaceRoot,
                    excludedAncestors: excludedAncestors
                )
            }
            let server = server(forWorkspaceRoot: directoryURL)
            lastActiveWorkspaceRoot = server.workspaceURL
            return server
        }

        if let activeRoot = lastActiveWorkspaceRoot ?? defaultWorkspaceRoot {
            return server(forWorkspaceRoot: activeRoot)
        }

        throw SwiftMCPError.communicationError(
            "No Swift workspace is active yet. Call a file-based tool first or pass `workspace_path`."
        )
    }

    /// Resolves a potentially relative file path against the active or default workspace root.
    public func resolvePath(_ filePath: String) -> String {
        resolveFileURL(filePath).path
    }

    /// Returns the currently active workspace root, if known.
    public func activeWorkspaceRoot() -> URL? {
        pinnedServer?.workspaceURL ?? lastActiveWorkspaceRoot ?? defaultWorkspaceRoot
    }

    /// Shuts down all managed `SwiftLanguageServer` sessions.
    public func shutdownAll() async {
        if let pinnedServer {
            await pinnedServer.shutdown()
            return
        }

        let servers = Array(serversByRoot.values)
        serversByRoot.removeAll()
        for server in servers {
            await server.shutdown()
        }
    }

    // MARK: - Project Discovery

    static func discoverProjectRoot(
        for fileURL: URL,
        fallbackRoot: URL? = nil,
        excludedAncestors: [URL] = buildExcludedAncestors()
    ) -> URL {
        let startDirectory = canonicalDirectoryURL(fileURL.deletingLastPathComponent())

        if let markerRoot = nearestDirectory(
            from: startDirectory,
            matching: hasBuildSystemMarker(at:)
        ) {
            return markerRoot
        }

        if let gitRoot = nearestDirectory(
            from: startDirectory,
            matching: { directory in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
            }
        ) {
            return gitRoot
        }

        if let fallbackRoot,
            isUsableWorkspaceRoot(fallbackRoot, excludedAncestors: excludedAncestors),
            isDescendant(fileURL, of: fallbackRoot)
        {
            return canonicalDirectoryURL(fallbackRoot)
        }

        return startDirectory
    }

    private func server(forWorkspaceRoot root: URL) -> SwiftLanguageServer {
        let canonical = Self.canonicalDirectoryURL(root)
        if let existing = serversByRoot[canonical] {
            return existing
        }

        let created = SwiftLanguageServer(logger: logger, workspaceRoot: canonical)
        serversByRoot[canonical] = created
        return created
    }

    private func resolveFileURL(_ filePath: String) -> URL {
        if let url = URL(string: filePath), url.isFileURL {
            return url.standardizedFileURL
        }

        if filePath.hasPrefix("/") {
            return URL(fileURLWithPath: filePath).standardizedFileURL
        }

        if let base = pinnedServer?.workspaceURL ?? lastActiveWorkspaceRoot ?? defaultWorkspaceRoot {
            return base.appendingPathComponent(filePath).standardizedFileURL
        }

        return URL(fileURLWithPath: filePath).standardizedFileURL
    }

    private static func workspaceCandidates(from params: JSONObject) -> [URL] {
        var urls: [URL] = []

        if let folders = params.array("workspaceFolders") {
            for folder in folders {
                if let uriString = folder.objectValue?.string("uri"),
                    let url = fileURL(fromURIOrPath: uriString)
                {
                    urls.append(url)
                }
            }
        }

        if let rootURI = params.string("rootUri"), let url = fileURL(fromURIOrPath: rootURI) {
            urls.append(url)
        }

        if let rootPath = params.string("rootPath"), let url = fileURL(fromURIOrPath: rootPath) {
            urls.append(url)
        }

        return urls
    }

    private static func fileURL(fromURIOrPath value: String) -> URL? {
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        return nil
    }

    private static func nearestDirectory(
        from startDirectory: URL,
        matching predicate: (URL) -> Bool
    ) -> URL? {
        let home = canonicalDirectoryURL(FileManager.default.homeDirectoryForCurrentUser)
        var current = startDirectory
        while !excludedRootNames.contains(current.path) && current.path != home.path {
            if predicate(current) {
                return current
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return nil
    }

    private static func hasBuildSystemMarker(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        for marker in projectMarkers {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(marker).path) {
                return true
            }
        }

        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.contains { entry in
            let ext = URL(fileURLWithPath: entry).pathExtension.lowercased()
            return xcodeProjectExtensions.contains(ext)
        }
    }

    private static func containsSwiftProjectMarkers(at directory: URL) -> Bool {
        if hasBuildSystemMarker(at: directory) {
            return true
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.contains {
            $0.hasSuffix(".swift") || $0.hasSuffix(".m") || $0.hasSuffix(".mm")
        }
    }

    private static func isUsableWorkspaceRoot(_ url: URL, excludedAncestors: [URL]) -> Bool {
        let canonical = canonicalDirectoryURL(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            return false
        }
        return !isExcludedDirectory(canonical, excludedAncestors: excludedAncestors)
    }

    private static func isExcludedDirectory(_ url: URL, excludedAncestors: [URL]) -> Bool {
        let path = canonicalDirectoryURL(url).path
        if excludedRootNames.contains(path) {
            return true
        }

        let home = canonicalDirectoryURL(FileManager.default.homeDirectoryForCurrentUser)
        if path == home.path {
            return true
        }

        for prefixURL in excludedAncestors {
            let prefixPath = prefixURL.path
            if path == prefixPath || path.hasPrefix(prefixPath + "/") {
                return true
            }
        }

        return false
    }

    private static func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let target = canonicalDirectoryURL(url).path
        let base = canonicalDirectoryURL(ancestor).path
        return target == base || target.hasPrefix(base + "/")
    }

    private static func canonicalDirectoryURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func buildExcludedAncestors(additionalPaths: [String] = []) -> [URL] {
        var result: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        result.append(canonicalDirectoryURL(home.appendingPathComponent(".gemini")))

        if let pluginRoot = ProcessInfo.processInfo.environment["PLUGIN_ROOT"], !pluginRoot.isEmpty {
            result.append(canonicalDirectoryURL(URL(fileURLWithPath: pluginRoot)))
        }

        for path in additionalPaths where !path.isEmpty {
            result.append(canonicalDirectoryURL(URL(fileURLWithPath: path)))
        }

        return result
    }
}
