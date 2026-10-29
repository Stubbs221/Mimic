//
//  XcodeBuildConnectionTests.swift
//  MimicAppTests
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation
import Testing
import MimicCore
@testable import Mimic

@MainActor struct XcodeBuildConnectionTests {
    @Test func nativeRunDoesNotReadOrRequestAccessibilityPermission() throws {
        try XcodeRunAccess.requireDebuggerAccess(native: true) {
            Issue.record("Native Run queried a permission needed only for toolbar progress")
            return false
        }
        #expect(throws: BuildError.xcodeDebuggerAccess) {
            try XcodeRunAccess.requireDebuggerAccess(native: false, hasAccess: { false })
        }
        try XcodeRunAccess.requireDebuggerAccess(native: false, hasAccess: { true })
    }

    @Test func branchAndCommitChangesReuseTheAuthorizedBridgeButXcodeRestartDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimicXcodeConnection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("App.xcworkspace").path
        let script = root.appendingPathComponent("bridge.py")
        // This process only speaks fixture MCP. It never opens Xcode, requests permission or runs a compiler.
        try """
        # Created by Василий Маслов on 27.10.2026.
        import json, sys
        workspace = sys.argv[1]
        schema = {"type": "object", "properties": {}}
        tools = [
            {"name": "XcodeListWindows", "inputSchema": schema,
             "outputSchema": {"type": "object", "properties": {"message": {"type": "string"}}}},
            {"name": "BuildProject", "inputSchema": {"type": "object", "properties": {"tabIdentifier": {"type": "string"}}},
             "outputSchema": {"type": "object", "properties": {"buildResult": {"type": "string"}, "errors": {"type": "array"}}}}
        ]
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request["method"]
            if method == "initialize":
                result = {"protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}
            elif method == "tools/list":
                result = {"tools": tools}
            elif method == "tools/call":
                result = {"content": [], "structuredContent": {"message": "tabIdentifier: fixture-tab, workspacePath: " + workspace}, "isError": False}
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)

        let fixture = FixtureState()
        let connection = XcodeBuildConnection(makeBridge: {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-u", script.path, workspace]
            fixture.children.append(child)
            return child
        }, runningXcode: { _ in fixture.processID })
        let developer = EnvironmentInspector.capture("/usr/bin/xcode-select", ["-p"]).1
        let first = ProjectContext(path: root.path, branch: "main", commit: "one", developerDirectory: developer, appleTarget: .init(path: "App.xcworkspace"))
        await connection.connect(project: first)
        try #require(connection.project == first, "Fixture handshake failed: \(connection.connectionFailure)")
        #expect(fixture.children.count == 1)
        var changed = first; changed.branch = "feature/test"; changed.commit = "two"
        await connection.connect(project: changed)
        #expect(connection.project == changed)
        #expect(fixture.children.count == 1, "A Git change created another agent and permission handshake")
        await connection.connect(project: changed)
        #expect(fixture.children.count == 1, "An explicit connection to the same workspace created another agent")
        #expect(fixture.children.first?.environment?["MCP_XCODE_SESSION_ID"] == nil)

        fixture.processID = 456
        await connection.connect(project: changed)
        #expect(connection.project == changed)
        #expect(fixture.children.count == 2, "A different Xcode process reused a stale connection")
        // Let the old bridge's termination handler arrive after the replacement is ready.
        try await Task.sleep(for: .milliseconds(150))
        #expect(connection.project == changed)
        #expect(fixture.children.last?.isRunning == true)
        await connection.disconnect()
        for _ in 0..<100 where fixture.children.contains(where: \.isRunning) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.children.allSatisfy { !$0.isRunning })
        #expect(connection.project == nil)
    }

    @MainActor private final class FixtureState {
        var processID: Int32 = 123
        var children: [Process] = []
    }

}
