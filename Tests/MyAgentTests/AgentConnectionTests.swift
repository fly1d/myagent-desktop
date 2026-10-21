import Foundation
import Testing
@testable import MyAgent

@MainActor
struct AgentConnectionTests {
    private enum FixtureFailure: Error { case missingRuntime, missingPython }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyAgent-connection-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private var bundledDevelopmentEngine: URL {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return project.appendingPathComponent("backend/target/debug/myagent-backend")
    }

    @Test
    func testIndependentBackendInitializesWithoutExistingCredentialsAndListsModels() async throws {
        let binary = bundledDevelopmentEngine
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            Issue.record("Build backend/Cargo.toml before running integration tests.")
            throw FixtureFailure.missingRuntime
        }
        let directory = try temporaryDirectory()
        let connection = AgentConnection()
        defer {
            connection.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        try await connection.launch(binary: binary, home: directory)
        let account = try await connection.call("account/read")
        #expect(account["account"] is NSNull, "A fresh application home must not inherit a login.")
        #expect(account["requiresOpenaiAuth"] as? Bool == true)
        let catalog = try await connection.call("model/list", params: ["limit": 20])
        _ = try #require(catalog["data"] as? [[String: Any]])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path))
    }

    @Test
    func testFragmentedFramesEventsAndBidirectionalToolRequests() async throws {
        let directory = try temporaryDirectory()
        let connection = AgentConnection()
        defer {
            connection.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let binary = try makeMockServer(in: directory)
        var events: [String] = []
        var requests: [String] = []
        connection.onEvent = { method, params in
            events.append(method)
            #expect(params["delta"] as? String == "分块消息")
        }
        connection.onServerRequest = { id, method, params in
            requests.append(method)
            #expect((id as? NSNumber)?.intValue == 901)
            #expect(params["tool"] as? String == "native_choice")
            connection.respond(id: id, result: [
                "success": true,
                "contentItems": [["type": "inputText", "text": "chosen"]]
            ])
        }
        let home = directory.appendingPathComponent("independent-home", isDirectory: true)
        try await connection.launch(binary: binary, home: home)
        let result = try await connection.call("test/roundtrip")
        #expect(result["ok"] as? Bool == true)
        #expect(result["home"] as? String == home.path)
        #expect(result["forbidden"] as? [String] == [])
        #expect(events == ["item/agentMessage/delta"])
        #expect(requests == ["item/tool/call"])
        let returnedTool = result["toolResult"] as? [String: Any]
        #expect(returnedTool?["success"] as? Bool == true)
        do {
            _ = try await connection.call("test/error")
            Issue.record("Expected the JSON-RPC error to reach the caller.")
        } catch {
            #expect(error.localizedDescription == "expected error")
        }
    }

    @Test
    func testStopRejectsPendingCallsAndUnexpectedExitClosesOnce() async throws {
        let directory = try temporaryDirectory()
        let connection = AgentConnection()
        defer {
            connection.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let binary = try makeMockServer(in: directory)
        let home = directory.appendingPathComponent("independent-home", isDirectory: true)
        var closes = 0
        connection.onClosed = { _ in closes += 1 }
        try await connection.launch(binary: binary, home: home)
        let held = Task { @MainActor in try await connection.call("test/hold") }
        try await Task.sleep(nanoseconds: 30_000_000)
        connection.stop()
        do { _ = try await held.value; Issue.record("Stopping must reject pending requests.") }
        catch { #expect(error.localizedDescription.contains("停止")) }
        #expect(closes == 0, "An intentional stop is not an unexpected-disconnection notification.")

        try await connection.launch(binary: binary, home: home)
        do { _ = try await connection.call("test/exit"); Issue.record("Exit must reject its pending request.") }
        catch { #expect(!error.localizedDescription.isEmpty) }
        #expect(closes == 1)
    }

    @Test
    func testCallerCancellationRejectsPendingCall() async throws {
        let directory = try temporaryDirectory()
        let connection = AgentConnection()
        defer {
            connection.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let binary = try makeMockServer(in: directory)
        try await connection.launch(binary: binary, home: directory.appendingPathComponent("independent-home"))
        let held = Task { @MainActor in try await connection.call("test/hold") }
        try await Task.sleep(nanoseconds: 30_000_000)
        held.cancel()
        do { _ = try await held.value; Issue.record("A cancelled caller must not retain its continuation.") }
        catch { #expect(error is CancellationError) }
    }

    private func makeMockServer(in directory: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            Issue.record("The transport fixture requires the macOS command line tools' Python.")
            throw FixtureFailure.missingPython
        }
        let file = directory.appendingPathComponent("mock-engine")
        let source = #"""
        #!/usr/bin/python3
        import json, os, sys, time
        waiting = None
        def send(value):
            data = (json.dumps(value, ensure_ascii=False) + '\n').encode()
            sys.stdout.buffer.write(data[:7]); sys.stdout.buffer.flush()
            time.sleep(0.001)
            sys.stdout.buffer.write(data[7:]); sys.stdout.buffer.flush()
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get('method')
            if method == 'initialize':
                send({'id': message['id'], 'result': {'userAgent': 'transport-fixture'}})
            elif method == 'initialized':
                pass
            elif method == 'test/roundtrip':
                waiting = message['id']
                send({'method': 'item/agentMessage/delta', 'params': {'threadId': 'thread', 'turnId': 'turn', 'itemId': 'item', 'delta': '分块消息'}})
                send({'id': 901, 'method': 'item/tool/call', 'params': {'tool': 'native_choice', 'arguments': {'a': 1}}})
            elif message.get('id') == 901 and 'result' in message:
                forbidden = [key for key in os.environ if key.startswith(('OPENAI_', 'DEEPSEEK_', 'CODEX_ACCESS')) or key == 'ACCESS_TOKEN']
                send({'id': waiting, 'result': {'ok': True, 'toolResult': message['result'], 'forbidden': forbidden, 'home': os.environ['CODEX_HOME']}})
            elif method == 'test/error':
                send({'id': message['id'], 'error': {'code': -32603, 'message': 'expected error'}})
            elif method == 'test/hold':
                pass
            elif method == 'test/exit':
                sys.exit(0)
        """#
        try Data(source.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}
