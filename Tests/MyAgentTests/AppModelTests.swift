import Foundation
import Testing
@testable import MyAgent

/// These tests use a local protocol fixture, not an OpenAI account or model.
@MainActor
struct AppModelTests {
    @Test(.timeLimit(.minutes(1)))
    func stoppedThreadStartReplyCannotOverwriteTheResumedThread() async throws {
        let fixture = try ModelServerFixture()
        try fixture.setScenario("late-thread-start")
        let model = AppModel(dataDirectory: fixture.directory.appendingPathComponent("data"), engineBinary: fixture.binary)
        do {
            await model.connect()
            model.draft = "first-thread-start-will-be-late"
            model.sendPrompt()
            try await eventually("first thread/start is held") { fixture.exists("first-thread-pending.json") }
            #expect(model.currentTask?.engineID == nil)
            model.stop()
            model.resumeTask()
            try await eventually("replacement thread is stored and running") {
                model.currentTask?.engineID == "replacement-thread" && model.currentTask?.phase == .running
            }
            try Data().write(to: fixture.directory.appendingPathComponent("release-old-thread"))
            try await eventually("client handles a request after the old thread response") { fixture.exists("post-late-probe-reply.json") }
            let probe = try fixture.readJSON("post-late-probe-reply.json")
            // An accepted request with an unknown tool returns a tool failure.
            // A stale engineID instead rejects the entire request as inactive.
            #expect(probe["error"] == nil)
            #expect((probe["result"] as? [String: Any])?["success"] as? Bool == false)
            #expect(model.currentTask?.engineID == "replacement-thread")
            #expect(model.currentTask?.phase == .running)
            model.stop()
            try await fixture.shutdown()
        } catch { model.stop(); try? await fixture.shutdown(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func stopInterruptsSubmittedClientTurnWithoutWaitingForRPCReply() async throws {
        let fixture = try ModelServerFixture()
        try fixture.setScenario("unacknowledged-turn")
        let model = AppModel(dataDirectory: fixture.directory.appendingPathComponent("data"), engineBinary: fixture.binary)
        do {
            await model.connect()
            model.draft = "turn-start-never-replies"
            model.sendPrompt()
            try await eventually("backend records turn before its RPC acknowledgment") { fixture.exists("unacknowledged-turn.json") }
            let pending = try #require(model.currentTask?.pendingTurnID)
            let submitted = try fixture.readJSON("unacknowledged-turn.json")
            #expect(submitted["turnId"] as? String == pending.lowercased())
            #expect(model.currentTask?.pendingInput == "turn-start-never-replies")
            model.stop()
            try await eventually("stop interrupts the unacknowledged client ID") { fixture.exists("unacknowledged-interrupt.json") }
            let interrupted = try fixture.readJSON("unacknowledged-interrupt.json")
            #expect(interrupted["turnId"] as? String == pending.lowercased())
            #expect(interrupted["threadId"] as? String == "own-thread")
            #expect(model.currentTask?.phase == .paused)
            #expect(!model.isBusy)
            #expect(!fixture.exists("turn-start-reply-sent"))
            try await fixture.shutdown()
        } catch { model.stop(); try? await fixture.shutdown(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func recoveryInterruptsAndWaitsForUnacknowledgedActiveTurnBeforeStartingNext() async throws {
        let fixture = try ModelServerFixture()
        try fixture.setScenario("recover-active")
        let root = fixture.directory.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clientID = UUID().uuidString.lowercased()
        var task = AgentTask(engineID: "own-thread", title: "先结束旧轮", workspace: fixture.workspace.path)
        task.messages = [ChatEntry(role: "user", text: "already-recorded-original")]
        task.phase = .paused
        task.pendingInput = "already-recorded-original"
        task.pendingTurnID = clientID
        task.draft = "不要发送这条草稿"
        try JSONEncoder().encode(PersistedAppState(selectedTaskID: task.id, tasks: [task], settings: AppSettings()))
            .write(to: root.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject: [["id": clientID, "status": "inProgress"]])
            .write(to: fixture.directory.appendingPathComponent("recorded-turns.json"))
        let model = AppModel(dataDirectory: root, engineBinary: fixture.binary)
        do {
            await model.connect()
            model.resumeTask()
            try await eventually("replacement starts after the old turn reaches terminal state") {
                fixture.exists("last-turn-request.json") && model.currentTask?.phase == .running
            }
            #expect(!fixture.exists("premature-turn-start.json"))
            let request = try fixture.readJSON("last-turn-request.json")
            let input = try #require((request["input"] as? [[String: Any]])?.first?["text"] as? String)
            #expect(input.contains("继续此任务"))
            #expect(request["clientTurnId"] as? String != clientID)
            let operations = try #require(fixture.readJSON("operations.json")["entries"] as? [[String: Any]])
            let interrupt = try #require(operations.firstIndex { $0["method"] as? String == "turn/interrupt" })
            let terminal = try #require(operations.firstIndex { $0["method"] as? String == "fixture/terminal" })
            let newTurn = try #require(operations.firstIndex { $0["method"] as? String == "turn/start" })
            #expect(interrupt < terminal && terminal < newTurn)
            #expect(operations.filter { $0["method"] as? String == "thread/resume" }.count >= 2)
            #expect(model.draft == "不要发送这条草稿")
            #expect(model.currentTask?.messages.filter { $0.text == "already-recorded-original" }.count == 1)
            #expect(model.currentTask?.pendingInput == nil)
            #expect(model.currentTask?.pendingTurnID == nil)
            model.stop()
            try await fixture.shutdown()
        } catch { model.stop(); try? await fixture.shutdown(); throw error }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func recoveryReconcilesUnacknowledgedTurnBeforeChoosingInput(wasRecorded: Bool) async throws {
        let fixture = try ModelServerFixture()
        let root = fixture.directory.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clientID = UUID().uuidString
        var task = AgentTask(engineID: "own-thread", title: "恢复确认", workspace: fixture.workspace.path)
        task.messages = [ChatEntry(role: "user", text: "original-unacknowledged-input")]
        task.phase = .paused
        task.draft = "尚未发送的新草稿"
        task.pendingInput = "original-unacknowledged-input"
        task.pendingTurnID = clientID
        let state = PersistedAppState(selectedTaskID: task.id, tasks: [task], settings: AppSettings())
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject: wasRecorded ? [["id": clientID.lowercased(), "status": "interrupted"]] : [])
            .write(to: fixture.directory.appendingPathComponent("recorded-turns.json"))
        let model = AppModel(dataDirectory: root, engineBinary: fixture.binary)
        do {
            await model.connect()
            #expect(model.canResumeTask)
            model.resumeTask()
            try await eventually("recovered turn reaches backend") {
                FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("last-turn-request.json").path)
                    && model.currentTask?.phase == .running
            }
            let request = try fixture.readJSON("last-turn-request.json")
            let sent = try #require((request["input"] as? [[String: Any]])?.first?["text"] as? String)
            #expect(wasRecorded ? sent.contains("继续此任务") : sent == "original-unacknowledged-input")
            #expect(wasRecorded ? request["clientTurnId"] as? String != clientID : request["clientTurnId"] as? String == clientID)
            #expect(model.draft == "尚未发送的新草稿")
            #expect(model.currentTask?.messages.filter { $0.text == "original-unacknowledged-input" }.count == 1)
            #expect(model.currentTask?.pendingInput == nil)
            #expect(model.currentTask?.pendingTurnID == nil)
            model.stop()
            try await fixture.shutdown()
        } catch { model.stop(); try? await fixture.shutdown(); throw error }
    }

    @Test
    func testUnsentFirstDraftSurvivesRestartWithoutCreatingFakeTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("myagent-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AppModel(dataDirectory: root)
        first.draft = "保留未发送的第一条输入"
        try await eventually("the debounced first draft is durably written") {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
                  let state = try? JSONDecoder().decode(PersistedAppState.self, from: data) else { return false }
            return state.unassignedDraft == "保留未发送的第一条输入"
        }
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
            #expect(Set(tools) == Set(["ask_user", "present_choices", "browser", "desktop", "complete_task"]))
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

    func setScenario(_ name: String) throws {
        try Data(name.utf8).write(to: directory.appendingPathComponent("scenario"))
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
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
    import json, os, pathlib, select, sys, time, uuid

    root = pathlib.Path(__file__).resolve().parent
    count = 0
    thread_count = 0
    waiting = {}
    first_turn = None
    turns_by_thread = {}
    active_turn = None
    terminal_at = None
    old_thread_reply = None
    probe_at = None
    operations = []

    def scenario():
        path = root / 'scenario'
        return path.read_text() if path.exists() else ''

    def send(value):
        sys.stdout.buffer.write((json.dumps(value, ensure_ascii=False) + '\n').encode('utf-8'))
        sys.stdout.buffer.flush()

    def record(name, value):
        temporary = root / (name + '.tmp')
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
        temporary.replace(root / name)

    def operation(method, extra=None):
        entry = {'method': method}; entry.update(extra or {})
        operations.append(entry)
        record('operations.json', {'entries': operations})

    def recorded_turns():
        path = root / 'recorded-turns.json'
        return json.loads(path.read_text()) if path.exists() else []

    def tick():
        global old_thread_reply, probe_at, terminal_at
        if old_thread_reply is not None and (root / 'release-old-thread').exists():
            send({'id': old_thread_reply, 'result': {'thread': {'id': 'obsolete-thread'}}})
            old_thread_reply = None
            probe_at = time.monotonic() + 0.1
        if probe_at is not None and time.monotonic() >= probe_at:
            probe_at = None
            send({'id': 'post-late-probe', 'method': 'item/tool/call', 'params': {
                'threadId': 'replacement-thread', 'turnId': turns_by_thread['replacement-thread'],
                'tool': 'unknown_fixture_probe', 'arguments': {}}})
        if terminal_at is not None and time.monotonic() >= terminal_at:
            terminal_at = None
            turns = recorded_turns()
            for turn in turns:
                if turn['status'] == 'inProgress': turn['status'] = 'interrupted'
            record('recorded-turns.json', turns)
            record('prior-turn-terminal.json', {'terminal': True})
            operation('fixture/terminal')

    def event(method, turn, extra=None, thread='own-thread'):
        params = {'threadId': thread, 'turnId': turn}
        params.update(extra or {})
        send({'method': method, 'params': params})

    def acknowledge_turn(identifier, turn):
        send({'id': identifier, 'result': {'turn': {'id': turn}}})
        record('turn-start-reply-sent', {'turnId': turn})

    def complete_request(identifier, turn, artifact):
        send({'id': identifier, 'method': 'item/tool/call', 'params': {
            'threadId': 'own-thread', 'turnId': turn, 'tool': 'complete_task',
            'arguments': {'summary': 'Local fixture verified the existing artifact',
                          'artifacts': [artifact],
                          'verification': ['Fixture prepared artifact.txt before executing the task']}}})

    def handle(message):
        global count, thread_count, old_thread_reply, first_turn, active_turn, terminal_at
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
            thread_count += 1
            names = sorted(tool.get('name') for tool in params.get('dynamicTools', []))
            instructions = params.get('developerInstructions', '')
            record('thread-request.json', {'tools': names, 'instructions': instructions, 'cwd': params.get('cwd'),
                'sandbox': params.get('sandbox'), 'approvalPolicy': params.get('approvalPolicy'), 'home': os.environ.get('CODEX_HOME')})
            expected = ['ask_user', 'browser', 'complete_task', 'desktop', 'present_choices']
            if names != expected or 'independently maintained macOS application' not in instructions:
                send({'id': identifier, 'error': {'code': -32602, 'message': 'Missing app-owned tools or instructions'}})
            else:
                if scenario() == 'late-thread-start' and thread_count == 1:
                    old_thread_reply = identifier
                    record('first-thread-pending.json', {'pending': True})
                else:
                    thread = 'replacement-thread' if scenario() == 'late-thread-start' else 'own-thread'
                    send({'id': identifier, 'result': {'thread': {'id': thread}}})
        elif method == 'thread/resume':
            turns = recorded_turns()
            operation('thread/resume', {'statuses': [turn['status'] for turn in turns]})
            send({'id': identifier, 'result': {'thread': {'id': 'own-thread', 'turns': turns}}})
        elif method == 'turn/start':
            if scenario() == 'recover-active' and any(turn['status'] == 'inProgress' for turn in recorded_turns()):
                record('premature-turn-start.json', params)
                send({'id': identifier, 'error': {'code': -32603, 'message': 'Old turn is still active'}})
                return
            record('last-turn-request.json', params)
            count += 1
            turn = str(uuid.UUID(params['clientTurnId']))
            if first_turn is None: first_turn = turn
            thread = params['threadId']
            turns_by_thread[thread] = turn
            active_turn = turn
            operation('turn/start', {'turnId': turn, 'threadId': thread})
            if scenario() == 'unacknowledged-turn':
                record('unacknowledged-turn.json', {'turnId': turn, 'threadId': thread})
                event('turn/started', turn, {'turn': {'id': turn, 'status': 'inProgress'}}, thread)
                return
            prompt = params.get('input', [{}])[0].get('text', '')
            if prompt in ['complete-existing-output', 'complete-missing-output']:
                # All of these deliberately precede the turn/start RPC reply.
                event('turn/started', turn, {'turn': {'id': turn}})
                event('item/agentMessage/delta', turn, {'itemId': 'assistant-fixture', 'delta': '本地协议夹具'})
                event('item/completed', turn, {'item': {'id': 'assistant-fixture', 'type': 'agentMessage', 'text': '本地协议夹具完成。'}})
                waiting['complete-request'] = turn
                complete_request('complete-request', turn, 'artifact.txt' if prompt == 'complete-existing-output' else 'does-not-exist.txt')
                acknowledge_turn(identifier, turn)
            else:
                acknowledge_turn(identifier, turn)
                event('turn/started', turn, {'turn': {'id': turn}}, thread)
                if prompt == 'start-new-turn-and-send-old-request':
                    complete_request('late-old-request', first_turn, 'artifact.txt')
        elif method == 'turn/interrupt':
            operation('turn/interrupt', params)
            if scenario() == 'unacknowledged-turn' and params.get('turnId') == active_turn:
                record('unacknowledged-interrupt.json', params)
            if scenario() == 'recover-active' and any(turn['id'] == params.get('turnId') and turn['status'] == 'inProgress' for turn in recorded_turns()):
                terminal_at = time.monotonic() + 0.15
            send({'id': identifier, 'result': {}})
        elif identifier == 'complete-request' and ('result' in message or 'error' in message):
            record('completion-tool-reply.json', message)
            turn = waiting.pop('complete-request')
            # A completed model turn alone must not turn an invalid receipt into acceptance.
            event('turn/completed', turn, {'turn': {'id': turn, 'status': 'completed'}})
        elif identifier == 'late-old-request' and ('result' in message or 'error' in message):
            record('late-tool-reply.json', message)
        elif identifier == 'post-late-probe' and ('result' in message or 'error' in message):
            record('post-late-probe-reply.json', message)
        elif identifier is not None:
            send({'id': identifier, 'error': {'code': -32601, 'message': 'Unsupported local fixture method'}})

    buffer = b''
    try:
        while not (root / 'stop-fixture').exists():
            tick()
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
