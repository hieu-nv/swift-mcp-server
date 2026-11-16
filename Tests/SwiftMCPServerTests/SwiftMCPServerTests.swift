import Logging
import XCTest

@testable import SourceKitLSP
@testable import SwiftMCPCore

final class SwiftMCPServerTests: XCTestCase {

    // MARK: - Protocol Shape

    func testMCPProtocolHandlerInitialization() throws {
        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger)
        let handler = MCPProtocolHandler(swiftLanguageServer: swiftLanguageServer, logger: logger)

        XCTAssertNotNil(handler)
    }

    func testMCPRequestDecodingSupportsNestedJSON() throws {
        let json = """
            {
                "jsonrpc": "2.0",
                "id": "test-id",
                "method": "tools/call",
                "params": {
                    "name": "find_symbols",
                    "arguments": {
                        "file_path": "/tmp/project/main.swift",
                        "name_pattern": "Greeter"
                    }
                }
            }
            """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let request = try JSONDecoder().decode(MCPRequest.self, from: data)

        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertEqual(request.method, "tools/call")
        XCTAssertEqual(request.params?.string("name"), "find_symbols")
        XCTAssertEqual(request.params?.object("arguments")?.string("file_path"), "/tmp/project/main.swift")
        XCTAssertEqual(request.params?.object("arguments")?.string("name_pattern"), "Greeter")
    }

    func testMCPResponseEncodingPreservesJSONObjectShape() throws {
        let response = MCPResponse(
            jsonrpc: "2.0",
            id: .string("test-id"),
            result: [
                "status": "ok",
                "count": 1,
            ]
        )

        let data = try JSONEncoder().encode(response)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(jsonObject["id"] as? String, "test-id")
        XCTAssertTrue(jsonObject["result"] is [String: Any])

        let result = try XCTUnwrap(jsonObject["result"] as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["count"] as? Int, 1)
    }

    func testToolsListExposesOnlySourceKitBackedTools() async throws {
        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger)
        let handler = MCPProtocolHandler(swiftLanguageServer: swiftLanguageServer, logger: logger)

        let request = MCPRequest(
            jsonrpc: "2.0",
            id: .string("tools"),
            method: "tools/list",
            params: [:]
        )

        let response = try await handler.handleRequest(request)
        let result = try XCTUnwrap(response.result?.objectValue)
        let tools = try XCTUnwrap(result["tools"]?.arrayValue)

        let toolNames = Set(tools.compactMap { $0.objectValue?.string("name") })
        XCTAssertEqual(
            toolNames,
            [
                "find_symbols",
                "find_references",
                "get_definition",
                "get_hover_info",
                "format_document",
                "get_diagnostics",
                "search_workspace_symbols",
                "rename_symbol",
                "call_hierarchy",
                "type_hierarchy",
                "get_implementations",
                "code_actions",
                "check_availability",
                "check_availability_matrix",
                "api_availability",
            ]
        )
    }

    func testUnknownToolReturnsToolNotFound() async throws {
        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger)
        let handler = MCPProtocolHandler(swiftLanguageServer: swiftLanguageServer, logger: logger)

        let request = MCPRequest(
            jsonrpc: "2.0",
            id: .string("call"),
            method: "tools/call",
            params: [
                "name": "analyze_project",
                "arguments": [:],
            ]
        )

        do {
            _ = try await handler.handleRequest(request)
            XCTFail("Expected a tool-not-found error for a removed tool")
        } catch let error as MCPError {
            if case .toolNotFound(let name) = error {
                XCTAssertEqual(name, "analyze_project")
            } else {
                XCTFail("Expected .toolNotFound, got \(error)")
            }
        }
    }

    func testToolFailureIsReportedAsToolResultWithMessage() async throws {
        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger)
        let handler = MCPProtocolHandler(swiftLanguageServer: swiftLanguageServer, logger: logger)
        defer { Task { await swiftLanguageServer.shutdown() } }

        let request = MCPRequest(
            jsonrpc: "2.0",
            id: .string("call"),
            method: "tools/call",
            params: [
                "name": "find_references",
                "arguments": [
                    "file_path": .string("/nonexistent/\(UUID().uuidString)/Missing.swift"),
                    "line": 0,
                    "character": 0,
                ],
            ]
        )

        let response = try await handler.handleRequest(request)
        let data = try JSONEncoder().encode(response)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(jsonObject["error"])
        let result = try XCTUnwrap(jsonObject["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.hasPrefix("Error: "), text)
        XCTAssertGreaterThan(text.count, "Error: ".count)
    }

    func testToolDefinition() throws {
        let tool = Tool(
            name: "find_symbols",
            description: "Find Swift symbols",
            inputSchema: [
                "type": "object",
                "properties": [
                    "file_path": ["type": "string"]
                ],
            ]
        )

        XCTAssertEqual(tool.name, "find_symbols")
        XCTAssertEqual(tool.description, "Find Swift symbols")
        XCTAssertEqual(tool.inputSchema.object("properties")?.object("file_path")?.string("type"), "string")
    }

    // MARK: - SourceKit-LSP Behaviour

    func testFormatDocumentUsesSourceKitLSP() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "FormattingWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceFile = workspace.appendingPathComponent("Sources/FormattingWorkspace/main.swift")

        try """
        import Foundation

        struct  Greeter{
        let name:String
        func greet()->String{
        "Hello, \\(name)"
        }
        }
        """
        .write(to: sourceFile, atomically: true, encoding: .utf8)

        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspace)
        defer { Task { await swiftLanguageServer.shutdown() } }

        let edits = try await swiftLanguageServer.formatDocument(at: sourceFile.path)
        XCTAssertFalse(edits.isEmpty)
    }

    func testDiagnosticsUseSourceKitLSP() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "DiagnosticsWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceFile = workspace.appendingPathComponent("Sources/DiagnosticsWorkspace/main.swift")

        try """
        import Foundation

        struct Greeter {
            let number: Int = "oops"
        }
        """
        .write(to: sourceFile, atomically: true, encoding: .utf8)

        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspace)
        defer { Task { await swiftLanguageServer.shutdown() } }

        let diagnostics = try await swiftLanguageServer.getDiagnostics(for: sourceFile.path)
        XCTAssertFalse(diagnostics.isEmpty)
        XCTAssertTrue(
            diagnostics.contains {
                $0.message.contains("Cannot convert value of type 'String' to specified type 'Int'")
            })
    }

    func testNavigationRequestsUseSourceKitLSP() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "NavigationWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourcesDirectory = workspace.appendingPathComponent("Sources/NavigationWorkspace")
        let definitionFile = sourcesDirectory.appendingPathComponent("Greeter.swift")
        let usageFile = sourcesDirectory.appendingPathComponent("main.swift")

        try """
        import Foundation

        struct Greeter {
            let name: String

            func greet() -> String {
                "Hello, \\(name)"
            }
        }
        """
        .write(to: definitionFile, atomically: true, encoding: .utf8)

        try """
        import Foundation

        let greeter = Greeter(name: "World")
        print(greeter.greet())
        """
        .write(to: usageFile, atomically: true, encoding: .utf8)

        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspace)
        defer { Task { await swiftLanguageServer.shutdown() } }

        let symbols = try await swiftLanguageServer.findSymbols(in: definitionFile.path, namePattern: "Greeter")
        XCTAssertTrue(symbols.contains { $0.name == "Greeter" && $0.kind == "struct" })

        let definition = try await swiftLanguageServer.getDefinition(
            at: Position(line: 2, character: 15),
            in: usageFile.path
        )
        XCTAssertFalse(definition.isEmpty)
        XCTAssertEqual(
            canonicalPath(URL(string: try XCTUnwrap(definition.first).targetUri)?.path),
            canonicalPath(definitionFile.path)
        )

        let references = try await swiftLanguageServer.findReferences(
            at: Position(line: 2, character: 8),
            in: definitionFile.path
        )
        XCTAssertTrue(
            references.contains { canonicalPath(URL(string: $0.uri)?.path) == canonicalPath(usageFile.path) }
        )

        let hover = try await swiftLanguageServer.getHover(
            at: Position(line: 2, character: 15),
            in: usageFile.path
        )
        XCTAssertNotNil(hover)

        switch hover?.contents {
        case .markupContent(let content):
            XCTAssertTrue(content.value.contains("Greeter"))
        case .markedString(let content):
            XCTAssertTrue(content.value.contains("Greeter"))
        case .none:
            XCTFail("Expected hover content")
        }
    }

    func testWorkspaceSymbolSearchFindsDeclaration() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "WorkspaceSymbolWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        try """
        struct UniqueGreeterType {
            func greet() -> String { "hi" }
        }
        """
        .write(
            to: workspace.appendingPathComponent("Sources/WorkspaceSymbolWorkspace/main.swift"),
            atomically: true,
            encoding: .utf8
        )

        let server = SwiftLanguageServer(logger: Logger(label: "test"), workspaceRoot: workspace)
        defer { Task { await server.shutdown() } }

        let symbols = try await server.searchWorkspaceSymbols(query: "UniqueGreeterType")
        XCTAssertTrue(symbols.contains { $0.name == "UniqueGreeterType" })
    }

    func testRenameSymbolRewritesDeclarationAndReferences() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "RenameWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/RenameWorkspace/main.swift")
        try """
        struct Greeter {
            func greet() -> String { "hi" }
        }

        let value = Greeter().greet()
        print(value)
        """
        .write(to: sourceFile, atomically: true, encoding: .utf8)

        let server = SwiftLanguageServer(logger: Logger(label: "test"), workspaceRoot: workspace)
        defer { Task { await server.shutdown() } }

        let edits = try await server.rename(
            at: Position(line: 0, character: 7), in: sourceFile.path, newName: "Welcomer")
        XCTAssertFalse(edits.isEmpty)

        let updated = try String(contentsOf: sourceFile, encoding: .utf8)
        XCTAssertTrue(updated.contains("struct Welcomer"))
        XCTAssertTrue(updated.contains("Welcomer().greet()"))
        XCTAssertFalse(updated.contains("Greeter"))
    }

    func testCallHierarchyFindsIncomingCaller() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "CallHierarchyWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/CallHierarchyWorkspace/main.swift")
        try """
        func makeGreeting() -> String { "hi" }

        func run() {
            _ = makeGreeting()
        }

        run()
        """
        .write(to: sourceFile, atomically: true, encoding: .utf8)

        let server = SwiftLanguageServer(logger: Logger(label: "test"), workspaceRoot: workspace)
        defer { Task { await server.shutdown() } }

        let callers = try await server.callHierarchy(
            at: Position(line: 0, character: 5), in: sourceFile.path, direction: .incoming)
        XCTAssertTrue(callers.contains { $0.name.contains("run") })
    }

    func testTypeHierarchyFindsConformer() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "TypeHierarchyWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/TypeHierarchyWorkspace/main.swift")
        try """
        protocol Greeter {
            func greet() -> String
        }

        struct EnglishGreeter: Greeter {
            func greet() -> String { "hi" }
        }
        """
        .write(to: sourceFile, atomically: true, encoding: .utf8)

        let server = SwiftLanguageServer(logger: Logger(label: "test"), workspaceRoot: workspace)
        defer { Task { await server.shutdown() } }

        let subtypes = try await server.typeHierarchy(
            at: Position(line: 0, character: 9), in: sourceFile.path, direction: .subtypes)
        XCTAssertTrue(subtypes.contains { $0.name.contains("EnglishGreeter") })
    }

    func testGetImplementationsFindsConcreteImpl() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "ImplementationsWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/ImplementationsWorkspace/main.swift")
        try """
        protocol Greeter {
            func greet() -> String
        }

        struct EnglishGreeter: Greeter {
            func greet() -> String { "hi" }
        }
        """
        .write(to: sourceFile, atomically: true, encoding: .utf8)

        let server = SwiftLanguageServer(logger: Logger(label: "test"), workspaceRoot: workspace)
        defer { Task { await server.shutdown() } }

        let implementations = try await server.getImplementations(
            at: Position(line: 1, character: 9), in: sourceFile.path)
        XCTAssertFalse(implementations.isEmpty)
    }

    func testCodeActionsListsAndAppliesFixIt() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "CodeActionWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/CodeActionWorkspace/main.swift")
        try """
        func run() {
            var message = "hi"
            print(message)
        }

        run()
        """
        .write(to: sourceFile, atomically: true, encoding: .utf8)

        let server = SwiftLanguageServer(logger: Logger(label: "test"), workspaceRoot: workspace)
        defer { Task { await server.shutdown() } }

        let actions = try await server.codeActions(atLine: 1, in: sourceFile.path)
        let fixTitle = try XCTUnwrap(actions.first(where: { $0.title.contains("let") })?.title)

        let edits = try await server.applyCodeAction(titled: fixTitle, atLine: 1, in: sourceFile.path)
        XCTAssertFalse(edits.isEmpty)

        let updated = try String(contentsOf: sourceFile, encoding: .utf8)
        XCTAssertTrue(updated.contains("let message"))
    }

    func testLanguageIdMappingByExtension() {
        func languageId(_ name: String) -> String {
            SourceKitLSPClient.languageId(for: URL(fileURLWithPath: "/tmp/\(name)"))
        }

        XCTAssertEqual(languageId("View.swift"), "swift")
        XCTAssertEqual(languageId("Legacy.m"), "objective-c")
        XCTAssertEqual(languageId("Bridge.mm"), "objective-cpp")
        XCTAssertEqual(languageId("Header.h"), "objective-c")
        XCTAssertEqual(languageId("core.c"), "c")
        XCTAssertEqual(languageId("engine.cpp"), "cpp")
        XCTAssertEqual(languageId("NoExtension"), "swift")
    }

    func testFindSourceKitLSPPrefersActiveToolchain() throws {
        #if os(macOS)
            try XCTSkipIf(
                ProcessInfo.processInfo.environment["SOURCEKIT_LSP_PATH"] != nil,
                "SOURCEKIT_LSP_PATH overrides discovery")

            let xcrun = Process()
            xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            xcrun.arguments = ["--find", "sourcekit-lsp"]
            let output = Pipe()
            xcrun.standardOutput = output
            xcrun.standardError = FileHandle.nullDevice
            try xcrun.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            xcrun.waitUntilExit()
            try XCTSkipIf(xcrun.terminationStatus != 0, "No active toolchain provides sourcekit-lsp")

            let activePath = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(SwiftLanguageServer.findSourceKitLSP(), activePath)
            XCTAssertNotNil(SwiftLanguageServer.toolchainVersion(forSourceKitLSP: activePath))
        #else
            throw XCTSkip("xcrun is macOS-only")
        #endif
    }

    func testWorkspaceManagerIgnoresNonProjectCurrentDirectory() async throws {
        let logger = Logger(label: "test")
        let pluginDir = try makeTemporaryPackage(named: "PluginBundle")
        defer { try? FileManager.default.removeItem(at: pluginDir) }

        let fromRoot = WorkspaceSessionManager(
            logger: logger,
            currentDirectoryURL: URL(fileURLWithPath: "/")
        )
        let rootActive = await fromRoot.activeWorkspaceRoot()
        XCTAssertNil(rootActive)

        let fromHome = WorkspaceSessionManager(
            logger: logger,
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let homeActive = await fromHome.activeWorkspaceRoot()
        XCTAssertNil(homeActive)

        let fromPlugin = WorkspaceSessionManager(
            logger: logger,
            currentDirectoryURL: pluginDir,
            additionalExcludedPaths: [pluginDir.path]
        )
        let pluginActive = await fromPlugin.activeWorkspaceRoot()
        XCTAssertNil(pluginActive)
    }

    func testWorkspaceManagerDiscoversAndRoutesSeparatePackages() async throws {
        let logger = Logger(label: "test")
        let packageOne = try makeTemporaryPackage(named: "PackageOne")
        let packageTwo = try makeTemporaryPackage(named: "PackageTwo")
        defer {
            try? FileManager.default.removeItem(at: packageOne)
            try? FileManager.default.removeItem(at: packageTwo)
        }

        let fileOne = packageOne.appendingPathComponent("Sources/PackageOne/One.swift")
        let fileTwo = packageTwo.appendingPathComponent("Sources/PackageTwo/Two.swift")
        try "struct One {}\n".write(to: fileOne, atomically: true, encoding: .utf8)
        try "struct Two {}\n".write(to: fileTwo, atomically: true, encoding: .utf8)

        let manager = WorkspaceSessionManager(
            logger: logger,
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )

        let (serverOne, resolvedOne) = await manager.server(forFilePath: fileOne.path)
        XCTAssertEqual(canonicalPath(serverOne.workspaceURL.path), canonicalPath(packageOne.path))
        XCTAssertEqual(resolvedOne, fileOne.standardizedFileURL.path)

        let (serverTwo, resolvedTwo) = await manager.server(forFilePath: fileTwo.path)
        XCTAssertEqual(canonicalPath(serverTwo.workspaceURL.path), canonicalPath(packageTwo.path))
        XCTAssertEqual(resolvedTwo, fileTwo.standardizedFileURL.path)
        XCTAssertFalse(serverOne === serverTwo)

        let active = await manager.activeWorkspaceRoot()
        XCTAssertEqual(canonicalPath(active?.path), canonicalPath(packageTwo.path))
    }

    func testWorkspaceManagerInitializeHintSetsDefaultWorkspace() async throws {
        let logger = Logger(label: "test")
        let package = try makeTemporaryPackage(named: "HintWorkspace")
        defer { try? FileManager.default.removeItem(at: package) }

        let manager = WorkspaceSessionManager(
            logger: logger,
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let handler = MCPProtocolHandler(workspaceManager: manager, logger: logger)
        defer { Task { await manager.shutdownAll() } }

        let initRequest = MCPRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "initialize",
            params: [
                "protocolVersion": "2024-11-05",
                "workspaceFolders": [
                    [
                        "uri": .string(package.absoluteString),
                        "name": "HintWorkspace",
                    ]
                ],
            ]
        )

        _ = try await handler.handleRequest(initRequest)
        let active = await manager.activeWorkspaceRoot()
        XCTAssertEqual(canonicalPath(active?.path), canonicalPath(package.path))

        let resolved = await manager.resolvePath("Sources/HintWorkspace/File.swift")
        XCTAssertEqual(
            canonicalPath(resolved),
            canonicalPath(package.appendingPathComponent("Sources/HintWorkspace/File.swift").path)
        )
    }

    func testSourceKitLSPClientSynchronizesIndexAndAcknowledgesServerRequests() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))

        let workspace = try makeTemporaryPackage(named: "FakeSyncWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/FakeSyncWorkspace/main.swift")
        try "struct Demo {}\n\nlet d = Demo()\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let fakeServer = workspace.appendingPathComponent("fake-lsp.py")
        try """
        #!/usr/bin/python3 -u
        import json, sys

        synchronized = False
        server_request_acked = False

        def send(msg):
            body = json.dumps(msg).encode("utf-8")
            sys.stdout.buffer.write(f"Content-Length: {len(body)}\\r\\n\\r\\n".encode("utf-8") + body)
            sys.stdout.buffer.flush()

        def read_msg():
            headers = b""
            while b"\\r\\n\\r\\n" not in headers:
                ch = sys.stdin.buffer.read(1)
                if not ch:
                    return None
                headers += ch
            length = 0
            for line in headers.decode("utf-8").split("\\r\\n"):
                if line.lower().startswith("content-length:"):
                    length = int(line.split(":", 1)[1].strip())
            body = sys.stdin.buffer.read(length)
            return json.loads(body.decode("utf-8"))

        while True:
            msg = read_msg()
            if msg is None:
                break
            if "method" not in msg and msg.get("id") == "srv-progress-1":
                server_request_acked = True
                continue
            method = msg.get("method")
            rid = msg.get("id")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": rid, "result": {"capabilities": {"referencesProvider": True}}})
                send({"jsonrpc": "2.0", "id": "srv-progress-1", "method": "window/workDoneProgress/create", "params": {"token": "idx"}})
            elif method == "workspace/synchronize":
                if msg.get("params", {}).get("index") is True:
                    synchronized = True
                send({"jsonrpc": "2.0", "id": rid, "result": {}})
            elif method == "textDocument/documentHighlight":
                send({"jsonrpc": "2.0", "id": rid, "result": []})
            elif method == "textDocument/references":
                uri = msg["params"]["textDocument"]["uri"]
                if synchronized and server_request_acked:
                    send({"jsonrpc": "2.0", "id": rid, "result": [
                        {"uri": uri, "range": {"start": {"line": 0, "character": 7}, "end": {"line": 0, "character": 11}}},
                        {"uri": uri, "range": {"start": {"line": 2, "character": 8}, "end": {"line": 2, "character": 12}}},
                    ]})
                else:
                    send({"jsonrpc": "2.0", "id": rid, "result": [
                        {"uri": uri, "range": {"start": {"line": 999, "character": 0}, "end": {"line": 999, "character": 1}}}
                    ]})
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": rid, "result": None})
            elif method == "exit":
                break
        """
        .write(to: fakeServer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeServer.path)

        let client = SourceKitLSPClient(
            executablePath: fakeServer.path,
            workspaceRoot: workspace,
            logger: Logger(label: "test")
        )
        defer { Task { await client.shutdown() } }

        let locations = try await client.references(
            fileURL: sourceFile,
            position: LSPPosition(line: 0, character: 7)
        )
        XCTAssertEqual(locations.map(\.range.start.line), [0, 2])
    }

    func testSourceKitLSPClientFallsBackToPollWhenSynchronizeUnsupported() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))

        let workspace = try makeTemporaryPackage(named: "FakeFallbackWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/FakeFallbackWorkspace/main.swift")
        try "struct Legacy {}\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let fakeServer = workspace.appendingPathComponent("fake-legacy-lsp.py")
        try """
        #!/usr/bin/python3 -u
        import json, sys

        ref_calls = 0

        def send(msg):
            body = json.dumps(msg).encode("utf-8")
            sys.stdout.buffer.write(f"Content-Length: {len(body)}\\r\\n\\r\\n".encode("utf-8") + body)
            sys.stdout.buffer.flush()

        def read_msg():
            headers = b""
            while b"\\r\\n\\r\\n" not in headers:
                ch = sys.stdin.buffer.read(1)
                if not ch:
                    return None
                headers += ch
            length = 0
            for line in headers.decode("utf-8").split("\\r\\n"):
                if line.lower().startswith("content-length:"):
                    length = int(line.split(":", 1)[1].strip())
            body = sys.stdin.buffer.read(length)
            return json.loads(body.decode("utf-8"))

        while True:
            msg = read_msg()
            if msg is None:
                break
            method = msg.get("method")
            rid = msg.get("id")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": rid, "result": {"capabilities": {"referencesProvider": True}}})
            elif method == "workspace/synchronize":
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})
            elif method == "textDocument/documentHighlight":
                send({"jsonrpc": "2.0", "id": rid, "result": []})
            elif method == "textDocument/references":
                ref_calls += 1
                uri = msg["params"]["textDocument"]["uri"]
                if ref_calls >= 2:
                    send({"jsonrpc": "2.0", "id": rid, "result": [
                        {"uri": uri, "range": {"start": {"line": 0, "character": 7}, "end": {"line": 0, "character": 13}}}
                    ]})
                else:
                    send({"jsonrpc": "2.0", "id": rid, "result": []})
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": rid, "result": None})
            elif method == "exit":
                break
        """
        .write(to: fakeServer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeServer.path)

        let client = SourceKitLSPClient(
            executablePath: fakeServer.path,
            workspaceRoot: workspace,
            logger: Logger(label: "test")
        )
        defer { Task { await client.shutdown() } }

        let locations = try await client.references(
            fileURL: sourceFile,
            position: LSPPosition(line: 0, character: 7)
        )
        XCTAssertEqual(locations.map(\.range.start.line), [0])
    }

    func testSourceKitLSPClientCancelsTimedOutSynchronizeAndProceedsBestEffort() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))

        let workspace = try makeTemporaryPackage(named: "FakeTimeoutWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/FakeTimeoutWorkspace/main.swift")
        try "struct Slow {}\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let fakeServer = workspace.appendingPathComponent("fake-timeout-lsp.py")
        try """
        #!/usr/bin/python3 -u
        import json, sys

        sync_id = None
        cancel_seen = False

        def send(msg):
            body = json.dumps(msg).encode("utf-8")
            sys.stdout.buffer.write(f"Content-Length: {len(body)}\\r\\n\\r\\n".encode("utf-8") + body)
            sys.stdout.buffer.flush()

        def read_msg():
            headers = b""
            while b"\\r\\n\\r\\n" not in headers:
                ch = sys.stdin.buffer.read(1)
                if not ch:
                    return None
                headers += ch
            length = 0
            for line in headers.decode("utf-8").split("\\r\\n"):
                if line.lower().startswith("content-length:"):
                    length = int(line.split(":", 1)[1].strip())
            body = sys.stdin.buffer.read(length)
            return json.loads(body.decode("utf-8"))

        while True:
            msg = read_msg()
            if msg is None:
                break
            method = msg.get("method")
            rid = msg.get("id")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": rid, "result": {"capabilities": {"referencesProvider": True}}})
            elif method == "workspace/synchronize":
                sync_id = rid
                # Intentionally do not reply so client times out and cancels.
            elif method == "$/cancelRequest":
                if msg.get("params", {}).get("id") == sync_id:
                    cancel_seen = True
            elif method == "textDocument/documentHighlight":
                send({"jsonrpc": "2.0", "id": rid, "result": []})
            elif method == "textDocument/references":
                uri = msg["params"]["textDocument"]["uri"]
                if cancel_seen:
                    send({"jsonrpc": "2.0", "id": rid, "result": [
                        {"uri": uri, "range": {"start": {"line": 0, "character": 7}, "end": {"line": 0, "character": 11}}}
                    ]})
                else:
                    send({"jsonrpc": "2.0", "id": rid, "result": []})
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": rid, "result": None})
            elif method == "exit":
                break
        """
        .write(to: fakeServer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeServer.path)

        let client = SourceKitLSPClient(
            executablePath: fakeServer.path,
            workspaceRoot: workspace,
            logger: Logger(label: "test"),
            indexSynchronizeTimeout: 0.25
        )
        defer { Task { await client.shutdown() } }

        let locations = try await client.references(
            fileURL: sourceFile,
            position: LSPPosition(line: 0, character: 7)
        )
        XCTAssertEqual(locations.map(\.range.start.line), [0])
    }

    func testFindReferencesSynchronizesAllTargetsAndReturnsEmptyQuicklyOnNonSymbol() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let coreDir = workspace.appendingPathComponent("Sources/CoreLib", isDirectory: true)
        let appDir = workspace.appendingPathComponent("Sources/App", isDirectory: true)
        let testDir = workspace.appendingPathComponent("Tests/CoreTests", isDirectory: true)
        try FileManager.default.createDirectory(at: coreDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        try """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "MultiTargetPkg",
            targets: [
                .target(name: "CoreLib"),
                .executableTarget(name: "App", dependencies: ["CoreLib"]),
                .testTarget(name: "CoreTests", dependencies: ["CoreLib"]),
            ]
        )
        """
        .write(to: workspace.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let coreFile = coreDir.appendingPathComponent("Core.swift")
        let appFile = appDir.appendingPathComponent("main.swift")
        let testFile = testDir.appendingPathComponent("CoreTests.swift")

        try """
        public struct CoreAPI {
            public init() {}
            public func ping() -> Int { 1 }
        }
        """
        .write(to: coreFile, atomically: true, encoding: .utf8)

        try """
        import CoreLib
        print(CoreAPI().ping())
        """
        .write(to: appFile, atomically: true, encoding: .utf8)

        try """
        import XCTest
        @testable import CoreLib
        final class CoreTests: XCTestCase {
            func testPing() { XCTAssertEqual(CoreAPI().ping(), 1) }
        }
        """
        .write(to: testFile, atomically: true, encoding: .utf8)

        let server = SwiftLanguageServer(logger: Logger(label: "test"), workspaceRoot: workspace)
        defer { Task { await server.shutdown() } }

        let references = try await server.findReferences(
            at: Position(line: 2, character: 16),
            in: coreFile.path
        )
        let referencedFiles = Set(references.compactMap { canonicalPath(URL(string: $0.uri)?.path) })
        XCTAssertEqual(
            referencedFiles,
            [
                canonicalPath(coreFile.path),
                canonicalPath(appFile.path),
                canonicalPath(testFile.path),
            ]
        )

        let emptyStart = Date()
        let keywordReferences = try await server.findReferences(
            at: Position(line: 0, character: 0),
            in: coreFile.path
        )
        let elapsed = Date().timeIntervalSince(emptyStart)
        XCTAssertTrue(keywordReferences.isEmpty)
        XCTAssertLessThan(elapsed, 5.0, "Non-symbol empty lookup should not stall for 20s poll timeout")
    }

    func testFindReferencesCoversLocalAndParameterSymbols() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "LocalSymbolsPkg")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/LocalSymbolsPkg/main.swift")
        try """
        import Foundation

        struct Formatter {
            func format(prefix: String, rawValue: String) -> String {
                func trim(_ input: String) -> String {
                    input.trimmingCharacters(in: .whitespaces)
                }
                let cleaned = trim(rawValue)
                return "\\(prefix): \\(cleaned)"
            }
        }

        print(Formatter().format(prefix: "ID", rawValue: " 42 "))
        """
        .write(to: sourceFile, atomically: true, encoding: .utf8)

        let server = SwiftLanguageServer(logger: Logger(label: "test"), workspaceRoot: workspace)
        defer { Task { await server.shutdown() } }

        let localRefs = try await server.findReferences(
            at: Position(line: 7, character: 12),
            in: sourceFile.path
        )
        XCTAssertEqual(localRefs.map(\.line), [7, 8])

        let nestedFuncRefs = try await server.findReferences(
            at: Position(line: 4, character: 13),
            in: sourceFile.path
        )
        XCTAssertEqual(nestedFuncRefs.map(\.line), [4, 7])

        let paramRefs = try await server.findReferences(
            at: Position(line: 7, character: 27),
            in: sourceFile.path
        )
        XCTAssertEqual(paramRefs.map(\.line), [3, 7])

        let typeRefs = try await server.findReferences(
            at: Position(line: 2, character: 7),
            in: sourceFile.path
        )
        XCTAssertEqual(typeRefs.map(\.line), [2, 12])
    }

    func testWorkspaceManagerDiscoversBuildServerJSONRoot() async throws {
        let outerRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outerRepo) }

        let gitDir = outerRepo.appendingPathComponent(".git", isDirectory: true)
        let bspAppDir = outerRepo.appendingPathComponent("ios-app", isDirectory: true)
        let sourcesDir = bspAppDir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try "{}\n".write(
            to: bspAppDir.appendingPathComponent("buildServer.json"),
            atomically: true,
            encoding: .utf8
        )
        let viewFile = sourcesDir.appendingPathComponent("View.swift")
        try "struct View {}\n".write(to: viewFile, atomically: true, encoding: .utf8)

        let manager = WorkspaceSessionManager(
            logger: Logger(label: "test"),
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        defer { Task { await manager.shutdownAll() } }

        let (server, _) = await manager.server(forFilePath: viewFile.path)
        XCTAssertEqual(canonicalPath(server.workspaceURL.path), canonicalPath(bspAppDir.path))
    }

    func testFindReferencesInXcodeProjectWithoutBuildServerReportsBSPNoteAndInFileHits() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let xcodeproj = projectRoot.appendingPathComponent("SampleXcodeApp.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        try "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {}; rootObject = AA; }\n"
            .write(to: xcodeproj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let helperFile = projectRoot.appendingPathComponent("Helper.swift")
        try "struct Helper {}\nlet localHelper = Helper()\n"
            .write(to: helperFile, atomically: true, encoding: .utf8)

        let manager = WorkspaceSessionManager(
            logger: Logger(label: "test"),
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let handler = MCPProtocolHandler(workspaceManager: manager, logger: Logger(label: "test"))
        defer { Task { await manager.shutdownAll() } }

        let hitRequest = MCPRequest(
            jsonrpc: "2.0",
            id: .string("xcode-hit"),
            method: "tools/call",
            params: [
                "name": "find_references",
                "arguments": [
                    "file_path": .string(helperFile.path),
                    "line": 0,
                    "character": 7,
                ],
            ]
        )
        let hitResponse = try await handler.handleRequest(hitRequest)
        let hitText = try XCTUnwrap(
            hitResponse.result?.objectValue?.array("content")?.first?.objectValue?.string("text")
        )
        XCTAssertTrue(hitText.contains(":0:7"), hitText)
        XCTAssertTrue(hitText.contains(":1:18"), hitText)
        XCTAssertTrue(hitText.contains("buildServer.json"), hitText)

        let emptyRequest = MCPRequest(
            jsonrpc: "2.0",
            id: .string("xcode-empty"),
            method: "tools/call",
            params: [
                "name": "find_references",
                "arguments": [
                    "file_path": .string(helperFile.path),
                    "line": 0,
                    "character": 0,
                ],
            ]
        )
        let emptyResponse = try await handler.handleRequest(emptyRequest)
        let emptyText = try XCTUnwrap(
            emptyResponse.result?.objectValue?.array("content")?.first?.objectValue?.string("text")
        )
        XCTAssertTrue(emptyText.hasPrefix("No results."), emptyText)
        XCTAssertTrue(emptyText.contains("buildServer.json"), emptyText)

        // Once buildServer.json is added, no Xcode BSP warning note should be emitted.
        try "{}\n".write(
            to: projectRoot.appendingPathComponent("buildServer.json"),
            atomically: true,
            encoding: .utf8
        )
        let configuredNote = await manager.indexingLimitationNote(forFilePath: helperFile.path)
        XCTAssertNil(configuredNote)
        let configuredEmptyResponse = try await handler.handleRequest(emptyRequest)
        let configuredEmptyText = try XCTUnwrap(
            configuredEmptyResponse.result?.objectValue?.array("content")?.first?.objectValue?.string("text")
        )
        XCTAssertEqual(configuredEmptyText, "No results.")
    }

    // MARK: - Helpers

    private func sourceKitLSPAvailable() -> Bool {
        let commonPaths = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
            "/usr/local/bin/sourcekit-lsp",
            "/opt/homebrew/bin/sourcekit-lsp",
            "/usr/bin/sourcekit-lsp",
        ]

        return commonPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private func canonicalPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func makeTemporaryPackage(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourcesDirectory = directory.appendingPathComponent("Sources/\(name)", isDirectory: true)

        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

        try """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "\(name)",
            targets: [
                .executableTarget(name: "\(name)")
            ]
        )
        """
        .write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        return directory
    }
}
