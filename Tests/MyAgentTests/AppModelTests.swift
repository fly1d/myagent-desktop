import Foundation
import Testing
@testable import MyAgent

/// These tests use a local protocol fixture, not an OpenAI account or model.
@MainActor
struct AppModelTests {
    @Test
    func testUnsentFirstDraftSurvivesRestartWithoutCreatingFakeTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("myagent-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AppModel(dataDirectory: root)
        first.draft = "保留未发送的第一条输入"
        try await Task.sleep(nanoseconds: 500_000_000)
        let restored = AppModel(dataDirectory: root)
        #expect(restored.draft == "保留未发送的第一条输入")
        #expect(restored.tasks.isEmpty)
    }
    @Test(.timeLimit(.minutes(1)))
    func testEarlyToolRequestProducesActualReceiptAndPersistsCompletedTask() async throws {
        try await withFixture { model, fixture in
            await model.connect()
            #expect(model.isConnected)
            #expect(model.accountLabel == "local-fixture@example.invalid")
            #expect(model.models.map(\.id) == ["fixture-model"])
            model.newTask()
            let taskID = try #require(model.selectedTaskID)
            try Data("actual fixture artifact\n".utf8).write(to: fixture.artifact)
            model.draft = "complete-existing-output"
            model.sendPrompt()

            try await eventually("valid completion after events arriving before turn/start response") {
                !model.isBusy && model.currentTask?.phase == .completed
            }
            #expect(model.lastError == nil)
            #expect(model.currentTask?.engineID == "own-thread")
            #expect(model.currentTask?.automaticRounds == 0)
            #expect(model.currentTask?.messages.contains { $0.role == "assistant" && $0.text == "本地协议夹具完成。" } == true)

            let threadRequest = try fixture.readJSON("thread-request.json")
            #expect(threadRequest["cwd"] as? String == fixture.workspace.path)
            #expect(threadRequest["sandbox"] as? String == "workspace-write")
            #expect(threadRequest["approvalPolicy"] as? String == "on-request")
            #expect(threadRequest["home"] as? String == fixture.directory.appendingPathComponent("data/engine").path)
            let tools = try #require(threadRequest["tools"] as? [String])
            #expect(Set(tools) == Set(["present_choices", "browser", "desktop", "complete_task"]))
            #expect((threadRequest["instructions"] as? String ?? "").contains("independently maintained macOS application"))

            let receipts = try fixture.receipts()
            #expect(receipts.count == 1)
            let receiptURL = try #require(receipts.first)
            let receipt = try fixture.readJSON(at: receiptURL)
            #expect(receipt["summary"] as? String == "Local fixture verified the existing artifact")
            #expect(receipt["artifacts"] as? [String] == [fixture.artifact.path])
            #expect(receipt["verification"] as? [String] == ["Fixture prepared artifact.txt before executing the task"])
            #expect(model.artifacts.contains { $0.path == receiptURL.path })

            let saved = try JSONDecoder().decode(PersistedAppState.self, from: Data(contentsOf: fixture.directory.appendingPathComponent("data/state.json")))
            #expect(saved.selectedTaskID == taskID)
            #expect(saved.tasks.first { $0.id == taskID }?.phase == .completed)
            #expect(saved.tasks.first { $0.id == taskID }?.engineID == "own-thread")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testBrowsingPreservesDraftAndLateRequestFromStoppedTurnCannotWriteReceipt() async throws {
        try await withFixture { model, fixture in
            await model.connect()
            model.newTask()
            let firstID = try #require(model.selectedTaskID)
            model.newTask()
            let secondID = try #require(model.selectedTaskID)
            model.selectTask(firstID)
            try Data("existing but not authorized for the late request\n".utf8).write(to: fixture.artifact)
            model.draft = "hold-first-turn"
            model.sendPrompt()
            try await eventually("initial held turn") { model.currentTask?.phase == .running }

            let count = model.tasks.count
            model.selectTask(secondID)
            #expect(model.selectedTaskID == secondID)
            model.draft = "second task draft"
            model.selectTask(firstID)
            model.selectTask(secondID)
            #expect(model.draft == "second task draft")
            model.newTask()
            #expect(model.tasks.count == count + 1)
            #expect(model.isBusy)
            model.selectTask(firstID)

            model.stop()
            #expect(!model.isBusy)
            #expect(model.currentTask?.phase == .paused)
            #expect(model.activeControlScope == nil)
            model.clearError()
            model.draft = "start-new-turn-and-send-old-request"
            model.sendPrompt()
            try await eventually("late request rejected while a new turn is active") {
                FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("late-tool-reply.json").path)
            }

            let reply = try fixture.readJSON("late-tool-reply.json")
            let error = try #require(reply["error"] as? [String: Any])
            #expect(error["message"] as? String == "Request belongs to an inactive turn.")
            #expect(model.isBusy)
            #expect(model.currentTask?.phase == .running)
            #expect(try fixture.receipts().isEmpty)
            #expect(!model.activities.contains { $0.title == "收到验收回执" })
            model.stop()
            #expect(model.currentTask?.phase == .paused)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testMissingArtifactCannotProduceAcceptedCompletion() async throws {
        try await withFixture { model, fixture in
            await model.connect()
            model.settings.proactive = false
            model.saveSettings()
            model.draft = "complete-missing-output"
            model.sendPrompt()
            try await eventually("invalid completion is held for review") {
                !model.isBusy && model.currentTask?.phase == .needsReview
            }

            let reply = try fixture.readJSON("completion-tool-reply.json")
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["success"] as? Bool == false)
            let content = try #require(result["contentItems"] as? [[String: Any]])
            let text = try #require(content.first?["text"] as? String)
            #expect(text.contains("error"))
            #expect(try fixture.receipts().isEmpty)
            #expect(model.currentTask?.automaticRounds == 0)
            #expect(!model.activities.contains { $0.title == "收到验收回执" })
        }
    }

    private func withFixture(_ body: (AppModel, ModelServerFixture) async throws -> Void) async throws {
        let fixture = try ModelServerFixture()
        let model = AppModel(dataDirectory: fixture.directory.appendingPathComponent("data"), engineBinary: fixture.binary)
        do {
            try await body(model, fixture)
        } catch {
            model.stop()
            try? await fixture.shutdown()
            throw error
        }
        model.stop()
        try await fixture.shutdown()
    }

    private func eventually(_ detail: String, timeout: TimeInterval = 6, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("Timed out waiting for \(detail)")
                throw ModelFixtureError.timeout
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private enum ModelFixtureError: Error {
    case missingPython, timeout
}

@MainActor
private final class ModelServerFixture {
    let directory: URL
    let binary: URL
    var workspace: URL { directory.appendingPathComponent("data/Workspace") }
    var artifact: URL { workspace.appendingPathComponent("artifact.txt") }

    init() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            Issue.record("The local AppModel protocol fixture requires /usr/bin/python3.")
            throw ModelFixtureError.missingPython
        }
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("MyAgent-model-fixture-\(UUID().uuidString)", isDirectory: true)
        binary = directory.appendingPathComponent("mock-app-server")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(Self.source.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    func readJSON(_ name: String) throws -> [String: Any] {
        try readJSON(at: directory.appendingPathComponent(name))
    }

    func readJSON(at file: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    func receipts() throws -> [URL] {
        let folder = workspace.appendingPathComponent("deliverables")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("receipt-") && $0.pathExtension == "json" }
    }

    func shutdown() async throws {
        try Data().write(to: directory.appendingPathComponent("stop-fixture"))
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture-exited").path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("The local fixture did not acknowledge shutdown")
                throw ModelFixtureError.timeout
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let EOF pass through the connection before removing its private home.
        try await Task.sleep(nanoseconds: 40_000_000)
        try FileManager.default.removeItem(at: directory)
    }

    private static let source = #"""
    #!/usr/bin/python3
    import json, os, pathlib, select, sys

    root = pathlib.Path(__file__).resolve().parent
    count = 0
    waiting = {}

    def send(value):
        sys.stdout.buffer.write((json.dumps(value, ensure_ascii=False) + '\n').encode('utf-8'))
        sys.stdout.buffer.flush()

    def record(name, value):
        temporary = root / (name + '.tmp')
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
        temporary.replace(root / name)

    def event(method, turn, extra=None):
        params = {'threadId': 'own-thread', 'turnId': turn}
        params.update(extra or {})
        send({'method': method, 'params': params})

    def complete_request(identifier, turn, artifact):
        send({'id': identifier, 'method': 'item/tool/call', 'params': {
            'threadId': 'own-thread', 'turnId': turn, 'tool': 'complete_task',
            'arguments': {'summary': 'Local fixture verified the existing artifact',
                          'artifacts': [artifact],
                          'verification': ['Fixture prepared artifact.txt before executing the task']}}})

    def handle(message):
        global count
        method = message.get('method')
        identifier = message.get('id')
        params = message.get('params', {})
        if method == 'initialize':
            send({'id': identifier, 'result': {'userAgent': 'local-model-fixture'}})
        elif method == 'initialized':
            pass
        elif method == 'account/read':
            send({'id': identifier, 'result': {'account': {'type': 'chatgpt', 'email': 'local-fixture@example.invalid'}}})
        elif method == 'model/list':
            send({'id': identifier, 'result': {'data': [{'id': 'fixture-model', 'model': 'fixture-model',
                'displayName': 'Local fixture only', 'isDefault': True}]}})
        elif method == 'thread/start':
            names = sorted(tool.get('name') for tool in params.get('dynamicTools', []))
            instructions = params.get('developerInstructions', '')
            record('thread-request.json', {'tools': names, 'instructions': instructions, 'cwd': params.get('cwd'),
                'sandbox': params.get('sandbox'), 'approvalPolicy': params.get('approvalPolicy'), 'home': os.environ.get('CODEX_HOME')})
            expected = ['browser', 'complete_task', 'desktop', 'present_choices']
            if names != expected or 'independently maintained macOS application' not in instructions:
                send({'id': identifier, 'error': {'code': -32602, 'message': 'Missing app-owned tools or instructions'}})
            else:
                send({'id': identifier, 'result': {'thread': {'id': 'own-thread'}}})
        elif method == 'thread/resume':
            send({'id': identifier, 'result': {'thread': {'id': 'own-thread'}}})
        elif method == 'turn/start':
            count += 1
            turn = 'turn-' + str(count)
            prompt = params.get('input', [{}])[0].get('text', '')
            if prompt in ['complete-existing-output', 'complete-missing-output']:
                # All of these deliberately precede the turn/start RPC reply.
                event('turn/started', turn, {'turn': {'id': turn}})
                event('item/agentMessage/delta', turn, {'itemId': 'assistant-fixture', 'delta': '本地协议夹具'})
                event('item/completed', turn, {'item': {'id': 'assistant-fixture', 'type': 'agentMessage', 'text': '本地协议夹具完成。'}})
                waiting['complete-request'] = turn
                complete_request('complete-request', turn, 'artifact.txt' if prompt == 'complete-existing-output' else 'does-not-exist.txt')
                send({'id': identifier, 'result': {'turn': {'id': turn}}})
            else:
                send({'id': identifier, 'result': {'turn': {'id': turn}}})
                event('turn/started', turn, {'turn': {'id': turn}})
                if prompt == 'start-new-turn-and-send-old-request':
                    complete_request('late-old-request', 'turn-1', 'artifact.txt')
        elif method == 'turn/interrupt':
            send({'id': identifier, 'result': {}})
        elif identifier == 'complete-request' and ('result' in message or 'error' in message):
            record('completion-tool-reply.json', message)
            turn = waiting.pop('complete-request')
            # A completed model turn alone must not turn an invalid receipt into acceptance.
            event('turn/completed', turn, {'turn': {'id': turn, 'status': 'completed'}})
        elif identifier == 'late-old-request' and ('result' in message or 'error' in message):
            record('late-tool-reply.json', message)
        elif identifier is not None:
            send({'id': identifier, 'error': {'code': -32601, 'message': 'Unsupported local fixture method'}})

    buffer = b''
    try:
        while not (root / 'stop-fixture').exists():
            readable, _, _ = select.select([sys.stdin.buffer], [], [], 0.02)
            if not readable:
                continue
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                if line.strip():
                    handle(json.loads(line))
    finally:
        (root / 'fixture-exited').write_text('done', encoding='utf-8')
    """#
}
