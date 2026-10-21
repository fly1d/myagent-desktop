import Foundation
import Testing
@testable import MyAgent

/// The production Swift controller and Rust binary communicate with an isolated
/// HTTP model fixture. Only the remote model is simulated; tools and storage are real.
@MainActor
struct BackendEndToEndTests {
    @Test(.timeLimit(.minutes(1)))
    func productionClientAndBackendWriteReadVerifyAndRestoreWithoutLeakingCredential() async throws {
        let fixture = try await HTTPModelFixture.start()
        let secrets = MemoryCredentialStore()
        let model = fixture.makeModel(secrets)
        do {
            let firstStartup = Task { await model.connect() }
            let secondStartup = Task { await model.connect() }
            await firstStartup.value
            await secondStartup.value
            #expect(model.isConnected)
            #expect(!model.isConnecting)
            try await configure(model, fixture)
            #expect(model.canRun)
            #expect(secrets.values.count == 1)
            model.settings.proactive = false
            model.draft = "write-report"
            model.sendPrompt()
            try await eventually("native write approval") { model.pendingPermission != nil }
            #expect(model.pendingPermission?.detail.contains("deliverables/report.txt") == true)
            #expect(model.pendingPermission?.detail.contains("你好，后端实际写入") == true)
            #expect(!FileManager.default.fileExists(atPath: fixture.report.path))
            model.respondPermission(true)
            try await eventually("actual verified task completion") { !model.isBusy }
            #expect(model.currentTask?.phase == .completed)
            #expect(try String(contentsOf: fixture.report, encoding: .utf8) == "你好，后端实际写入。\n")
            #expect(try fixture.receipts().count == 1)
            #expect(model.currentTask?.messages.contains { $0.text == "已写入、读回并验收。" } == true)
            let taskID = try #require(model.selectedTaskID)
            model.draft = "退出前未发送的草稿"
            try await model.shutdownAndWait()

            let reopened = fixture.makeModel(secrets)
            await reopened.connect()
            #expect(reopened.canRun)
            #expect(reopened.selectedTaskID == taskID)
            #expect(reopened.draft == "退出前未发送的草稿")
            #expect(reopened.currentTask?.phase == .completed)
            try await reopened.shutdownAndWait()
            let snapshot = try Data(contentsOf: fixture.data.appendingPathComponent("state.json"))
            let database = try Data(contentsOf: fixture.data.appendingPathComponent("engine/myagent.sqlite"))
            let secretBytes = Data(HTTPModelFixture.key.utf8)
            let credentialLeaked = snapshot.range(of: secretBytes) != nil || database.range(of: secretBytes) != nil
            #expect(!credentialLeaked)
            #expect(fixture.requestCount >= 4)
        } catch {
            try? await model.shutdownAndWait()
            fixture.stop()
            throw error
        }
        fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func decliningWriteIsFinalAndLeavesNoFileOrAcceptedReceipt() async throws {
        let fixture = try await HTTPModelFixture.start()
        let model = fixture.makeModel(MemoryCredentialStore())
        do {
            await model.connect()
            try await configure(model, fixture)
            model.settings.proactive = false
            model.draft = "deny-write"
            model.sendPrompt()
            var requests = Set<UUID>()
            try await eventually("denied tool action finishes without a repeat prompt") {
                if let request = model.pendingPermission, requests.insert(request.id).inserted { model.respondPermission(false) }
                return !model.isBusy
            }
            #expect(requests.count == 1)
            #expect(model.currentTask?.phase == .needsReview)
            #expect(!FileManager.default.fileExists(atPath: fixture.report.path))
            #expect(try fixture.receipts().isEmpty)
            try await model.shutdownAndWait()
        } catch { try? await model.shutdownAndWait(); fixture.stop(); throw error }
        fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedCredentialSaveDoesNotActivateProvider() async throws {
        let fixture = try await HTTPModelFixture.start()
        let secrets = MemoryCredentialStore()
        secrets.failWrites = true
        let model = fixture.makeModel(secrets)
        do {
            await model.connect()
            model.providerDraft = fixture.provider
            model.apiKeyDraft = HTTPModelFixture.key
            model.saveConnection()
            try await eventually("credential storage failure is reported") { !model.isTestingConnection }
            #expect(model.connectionTestStatus.contains("模拟钥匙串拒绝保存"))
            #expect(!model.hasCredentials)
            #expect(!model.canRun)
            #expect(secrets.values.isEmpty)
            #expect(fixture.requestCount == 0)
            try await model.shutdownAndWait()
        } catch { try? await model.shutdownAndWait(); fixture.stop(); throw error }
        fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func backendFailureAfterCredentialSaveRestoresPreviousKey() async throws {
        let fixture = try await HTTPModelFixture.start()
        let secrets = MemoryCredentialStore()
        let model = fixture.makeModel(secrets)
        let account = "custom|" + fixture.address
        let previous = "previous-test-key-not-a-real-credential"
        secrets.values[account] = previous
        do {
            await model.connect()
            model.providerDraft = fixture.provider
            model.apiKeyDraft = HTTPModelFixture.key
            secrets.onSave = { model.shutdown() }
            model.saveConnection()
            try await eventually("provider failure rolls back its saved key") { !model.isTestingConnection }
            #expect(secrets.values[account] == previous)
            #expect(!model.canRun)
            #expect(model.connectionTestStatus.hasPrefix("连接失败"))
            try await model.shutdownAndWait()
        } catch { try? await model.shutdownAndWait(); fixture.stop(); throw error }
        fixture.stop()
    }

    private func configure(_ model: AppModel, _ fixture: HTTPModelFixture) async throws {
        model.providerDraft = fixture.provider
        model.apiKeyDraft = HTTPModelFixture.key
        model.saveConnection()
        try await eventually("provider connection saves") { !model.isTestingConnection }
        #expect(model.connectionTestStatus.hasPrefix("连接成功"))
        #expect(model.apiKeyDraft.isEmpty)
        #expect(model.canRun)
    }

    private func eventually(_ detail: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() {
            guard Date() < deadline else { throw AppFailure.message("Timed out: " + detail) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private final class HTTPModelFixture {
    static let key = "myagent-e2e-fixture-key-not-a-real-credential"
    let directory: URL
    let process = Process()
    var address = ""
    var data: URL { directory.appendingPathComponent("data") }
    var report: URL { data.appendingPathComponent("Workspace/deliverables/report.txt") }
    var provider: ProviderDraft { ProviderDraft(kind: "custom", baseURL: address, model: "fixture-agent") }
    var requestCount: Int { ((try? Data(contentsOf: directory.appendingPathComponent("requests.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? Int }) ?? 0 }

    private init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("myagent-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("model.py")
        try Data(Self.source.utf8).write(to: script)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, directory.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func start() async throws -> HTTPModelFixture {
        let fixture = try HTTPModelFixture()
        let deadline = Date().addingTimeInterval(5)
        while true {
            if let text = try? String(contentsOf: fixture.directory.appendingPathComponent("address.txt"), encoding: .utf8) {
                fixture.address = text
                return fixture
            }
            guard Date() < deadline, fixture.process.isRunning else { fixture.stop(); throw AppFailure.message("HTTP model fixture did not start") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func makeModel(_ secrets: MemoryCredentialStore) -> AppModel {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return AppModel(dataDirectory: data, engineBinary: root.appendingPathComponent("backend/target/debug/myagent-backend"), credentialStore: secrets, usesBackendPersistence: true)
    }

    func receipts() throws -> [URL] {
        let folder = report.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("receipt-") }
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }

    private static let source = #"""
    import http.server, json, pathlib, sys
    root = pathlib.Path(sys.argv[1]); count = 0
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            if self.path != '/v1/models': self.send_error(404); return
            data = json.dumps({'data':[{'id':'fixture-agent'}]}).encode()
            self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            global count
            if self.path != '/v1/chat/completions': self.send_error(404); return
            if self.headers.get('Authorization') != 'Bearer myagent-e2e-fixture-key-not-a-real-credential': self.send_error(401); return
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert request['model'] == 'fixture-agent'
            names = {t['function']['name'] for t in request['tools']}
            assert {'write_file','read_file','complete_task'}.issubset(names)
            count += 1; (root/'requests.json').write_text(json.dumps(count))
            messages = request['messages']; user_index = max(i for i,m in enumerate(messages) if m['role']=='user')
            mode = messages[user_index]['content']; results = [m for m in messages[user_index+1:] if m['role']=='tool']; stage=len(results)
            call = None; text = ''
            if mode == 'deny-write':
                if stage < 2: call = ('write_file', {'path':'deliverables/report.txt','content':'你好，后端实际写入。\n'})
                else: text = '用户拒绝，未写入文件。'
            elif stage == 0: call = ('write_file', {'path':'deliverables/report.txt','content':'你好，后端实际写入。\n'})
            elif stage == 1: call = ('read_file', {'path':'deliverables/report.txt'})
            elif stage == 2:
                actual = json.loads(results[-1]['content'])
                assert actual['content'] == '你好，后端实际写入。\n'
                call = ('complete_task', {'summary':'真实后端已写入并读回项目文件','artifacts':['deliverables/report.txt'],'verification':['read_file 实际返回预期的中文文件内容']})
            else: text = '已写入、读回并验收。'
            self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
            def event(delta, reason=None):
                data = {'choices':[{'index':0,'delta':delta,'finish_reason':reason}]}
                self.wfile.write(('data: '+json.dumps(data,ensure_ascii=False)+'\n\n').encode()); self.wfile.flush()
            if call:
                name,args=call
                event({'tool_calls':[{'index':0,'id':'call-'+str(count),'type':'function','function':{'name':name,'arguments':json.dumps(args,ensure_ascii=False)}}]})
                event({},'tool_calls')
            else: event({'content':text}); event({},'stop')
            self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    (root/'address.txt').write_text('http://127.0.0.1:'+str(server.server_port)+'/v1')
    server.serve_forever()
    """#
}
