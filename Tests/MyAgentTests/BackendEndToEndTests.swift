import Foundation
import Testing
@testable import MyAgent

/// The production Swift controller and Rust binary communicate with an isolated
/// HTTP model fixture. Only the remote model is simulated; tools and storage are real.
@Suite(.serialized)
@MainActor
struct BackendEndToEndTests {
    @Test(.timeLimit(.minutes(1)))
    func localUnauthenticatedDiscoveryDeliveryAndDisconnectNeverTouchCredentialStore() async throws {
        let fixture = try await HTTPModelFixture.start(allowUnauthenticated: true)
        let secrets = RejectingCredentialStore()
        let model = fixture.makeModel(secrets)
        var reopened: AppModel?
        var afterDisconnect: AppModel?
        do {
            await model.connect()
            var local = ProviderDraft(kind: "local", baseURL: fixture.address, model: "")
            local.authentication = .some(.none)
            model.providerDraft = local
            model.apiKeyDraft = ""
            model.saveConnection()
            try await eventually("empty model cannot be saved even for local no-key mode") { !model.isTestingConnection }
            #expect(model.connectionTestStatus.hasPrefix("连接失败"))
            #expect(!model.canRun)
            #expect(fixture.httpRequests.isEmpty)
            #expect(secrets.operations.isEmpty)

            model.testConnection()
            try await eventually("local endpoint discovers its single real model") { !model.isTestingConnection }
            #expect(model.connectionTestStatus.hasPrefix("连接成功"))
            #expect(model.providerDraft.model == "fixture-agent")
            #expect(fixture.httpRequests.contains { $0["method"] as? String == "GET" && $0["path"] as? String == "/v1/models" })
            #expect(secrets.operations.isEmpty)
            model.saveConnection()
            try await eventually("local connection saves without a key") { !model.isTestingConnection }
            #expect(model.connectionTestStatus.hasPrefix("连接成功"))
            #expect(model.canRun)
            #expect(model.apiKeyDraft.isEmpty)
            model.settings.proactive = false
            model.draft = "write-report"
            model.sendPrompt()
            try await eventually("no-key task reaches real file approval") { model.pendingPermission != nil }
            model.respondPermission(true)
            try await eventually("no-key task writes reads and verifies") { !model.isBusy }
            #expect(model.currentTask?.phase == .completed)
            #expect(try String(contentsOf: fixture.report, encoding: .utf8) == "你好，后端实际写入。\n")
            #expect(try fixture.receipts().count == 1)
            #expect(secrets.operations.isEmpty)
            let taskID = try #require(model.selectedTaskID)
            try await model.shutdownAndWait()

            let restored = fixture.makeModel(secrets)
            reopened = restored
            await restored.connect()
            #expect(restored.canRun)
            #expect(restored.selectedTaskID == taskID)
            #expect(restored.currentTask?.phase == .completed)
            #expect(restored.providerDraft.kind == "local")
            #expect(restored.providerDraft.baseURL == fixture.address)
            #expect(restored.providerDraft.model == "fixture-agent")
            #expect(restored.providerDraft.authentication == .some(.none))
            #expect(secrets.operations.isEmpty)
            restored.disconnectProvider()
            try await eventually("local provider disconnects") { !restored.canRun }
            try await restored.shutdownAndWait()

            let disconnected = fixture.makeModel(secrets)
            afterDisconnect = disconnected
            await disconnected.connect()
            #expect(!disconnected.canRun)
            #expect(disconnected.isConnected)
            #expect(disconnected.providerDraft.kind == "local")
            #expect(disconnected.providerDraft.baseURL == fixture.address)
            #expect(disconnected.providerDraft.model == "fixture-agent")
            #expect(disconnected.providerDraft.authentication == .some(.none))
            #expect(secrets.operations.isEmpty)
            #expect(!fixture.httpRequests.isEmpty)
            #expect(fixture.httpRequests.allSatisfy { $0["authorizationPresent"] as? Bool == false })
            try await disconnected.shutdownAndWait()
        } catch {
            try? await model.shutdownAndWait()
            if let reopened { try? await reopened.shutdownAndWait() }
            if let afterDisconnect { try? await afterDisconnect.shutdownAndWait() }
            fixture.stop()
            throw error
        }
        fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func localNoKeyTestAndSaveWithUnavailableBackendDoNotReadPreviousProviderKey() async throws {
        let fixture = try await HTTPModelFixture.start()
        let secrets = GateableCredentialStore()
        let model = fixture.makeModel(secrets)
        do {
            await model.connect()
            try await configure(model, fixture)
            #expect(secrets.values.count == 1)
            let originalKeys = secrets.values
            let originalOperations = secrets.operations
            let originalRequests = fixture.httpRequests.count
            try await model.shutdownAndWait()
            #expect(!model.isConnected)
            secrets.rejectReads = true
            try Data().write(to: fixture.directory.appendingPathComponent("allow-unauthenticated-local-fixture"))

            model.providerDraft = ProviderDraft(kind: "local", baseURL: fixture.address, model: "", authentication: .some(.none))
            model.apiKeyDraft = ""
            model.testConnection()
            try await eventually("local no-key discovery starts an unavailable backend without restoring the old key") { !model.isTestingConnection }
            #expect(model.connectionTestStatus.hasPrefix("连接成功"))
            #expect(model.providerDraft.kind == "local")
            #expect(model.providerDraft.model == "fixture-agent")
            #expect(model.providerDraft.authentication == .some(.none))
            #expect(model.lastError == nil)
            #expect(secrets.operations == originalOperations)
            #expect(secrets.values == originalKeys)
            #expect(!model.canRun)

            // Saving must also survive a fresh backend start while the old
            // enabled key configuration still exists in persistent state.
            try await model.shutdownAndWait()
            #expect(!model.isConnected)
            model.saveConnection()
            try await eventually("local no-key save starts an unavailable backend without reading the old key") { !model.isTestingConnection }
            #expect(model.connectionTestStatus.hasPrefix("连接成功"))
            #expect(model.canRun)
            #expect(model.lastError == nil)
            #expect(secrets.operations == originalOperations)
            #expect(secrets.values == originalKeys)

            model.settings.proactive = false
            model.draft = "write-report"
            model.sendPrompt()
            try await eventually("replacement no-key provider reaches actual file approval") { model.pendingPermission != nil }
            model.respondPermission(true)
            try await eventually("replacement no-key provider completes actual delivery") { !model.isBusy }
            #expect(model.currentTask?.phase == .completed)
            #expect(try String(contentsOf: fixture.report, encoding: .utf8) == "你好，后端实际写入。\n")
            #expect(try fixture.receipts().count == 1)
            #expect(model.lastError == nil)
            #expect(secrets.operations == originalOperations)
            #expect(secrets.values == originalKeys)
            let localRequests = fixture.httpRequests.dropFirst(originalRequests)
            #expect(!localRequests.isEmpty)
            #expect(localRequests.allSatisfy { $0["authorizationPresent"] as? Bool == false })
            try await model.shutdownAndWait()
        } catch { try? await model.shutdownAndWait(); fixture.stop(); throw error }
        fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteUnauthenticatedDraftIsRejectedBeforeHTTPAndKeepsWorkingSavedProvider() async throws {
        let fixture = try await HTTPModelFixture.start()
        let secrets = MemoryCredentialStore()
        let model = fixture.makeModel(secrets)
        do {
            await model.connect()
            try await configure(model, fixture)
            let savedKeys = secrets.values
            let credentialReads = secrets.attemptedAccounts.count
            let requests = fixture.httpRequests.count
            var remote = ProviderDraft(kind: "custom", baseURL: "https://must-not-contact.invalid/v1", model: "fixture-agent")
            remote.authentication = .some(.none)
            model.providerDraft = remote
            model.apiKeyDraft = ""
            model.testConnection()
            try await eventually("remote no-key discovery is blocked") { !model.isTestingConnection }
            #expect(model.connectionTestStatus.hasPrefix("连接失败"))
            #expect(model.connectionTestStatus.contains("无密钥模式仅支持本机地址"))
            #expect(fixture.httpRequests.count == requests)
            #expect(secrets.attemptedAccounts.count == credentialReads)
            #expect(secrets.values == savedKeys)
            #expect(model.canRun)
            model.saveConnection()
            try await eventually("remote no-key save is blocked") { !model.isTestingConnection }
            #expect(model.connectionTestStatus.hasPrefix("连接失败"))
            #expect(model.connectionTestStatus.contains("无密钥模式仅支持本机地址"))
            #expect(fixture.httpRequests.count == requests)
            #expect(secrets.attemptedAccounts.count == credentialReads)
            #expect(secrets.values == savedKeys)
            #expect(model.canRun)

            // A runnable label alone is insufficient: the previous saved key
            // and endpoint must still complete a real production tool loop.
            model.settings.proactive = false
            model.draft = "write-report"
            model.sendPrompt()
            try await eventually("saved key provider still requests its actual write") { model.pendingPermission != nil }
            model.respondPermission(true)
            try await eventually("saved provider survives invalid draft") { !model.isBusy }
            #expect(model.currentTask?.phase == .completed)
            #expect(try String(contentsOf: fixture.report, encoding: .utf8) == "你好，后端实际写入。\n")
            #expect(try fixture.receipts().count == 1)
            #expect(secrets.values == savedKeys)
            #expect(fixture.httpRequests.allSatisfy { $0["authorizationPresent"] as? Bool == true })
            try await model.shutdownAndWait()
        } catch { try? await model.shutdownAndWait(); fixture.stop(); throw error }
        fixture.stop()
    }

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

    @Test(.timeLimit(.minutes(1)))
    func openQuestionAnswerFlowsThroughRealBackendIntoVerifiedFile() async throws {
        let fixture = try await HTTPModelFixture.start()
        let model = fixture.makeModel(MemoryCredentialStore())
        do {
            await model.connect()
            try await configure(model, fixture)
            model.settings.proactive = false
            model.draft = "ask-open-question"
            model.sendPrompt()
            try await eventually("native open question") { model.pendingQuestion != nil }
            let question = try #require(model.pendingQuestion)
            #expect(question.question == "这份报告应该写给谁？")
            #expect(question.context == "需要称呼来生成报告。")
            #expect(question.placeholder == "例如：开发团队")
            #expect(question.options.isEmpty)
            #expect(model.pendingPermission == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.report.path))
            model.answerQuestion("开发团队")
            try await eventually("file approval after actual question tool result") { model.pendingPermission != nil }
            #expect(model.pendingQuestion == nil)
            #expect(model.pendingPermission?.detail.contains("致开发团队") == true)
            #expect(fixture.lastQuestionResult?["answer"] as? String == "开发团队")
            #expect(fixture.lastQuestionResult?["cancelled"] as? Bool == false)
            model.respondPermission(true)
            try await eventually("question answer produces verified deliverable") { !model.isBusy }
            #expect(model.currentTask?.phase == .completed)
            #expect(try String(contentsOf: fixture.report, encoding: .utf8) == "致开发团队：你好，后端实际写入。\n")
            #expect(try fixture.receipts().count == 1)
            #expect(model.currentTask?.messages.contains { $0.text == "已根据回答写入、读回并验收。" } == true)
            try await model.shutdownAndWait()
        } catch { try? await model.shutdownAndWait(); fixture.stop(); throw error }
        fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func dismissingQuestionReturnsCancellationAndIgnoresLateAnswer() async throws {
        let fixture = try await HTTPModelFixture.start()
        let model = fixture.makeModel(MemoryCredentialStore())
        do {
            await model.connect()
            try await configure(model, fixture)
            model.settings.proactive = false
            model.draft = "ask-cancel-question"
            model.sendPrompt()
            try await eventually("question to cancel") { model.pendingQuestion != nil }
            model.dismissQuestion()
            model.answerQuestion("迟到回答不能触发交付")
            try await eventually("cancelled answer reaches model without delivery") { !model.isBusy }
            #expect(model.pendingQuestion == nil)
            #expect(model.pendingPermission == nil)
            #expect(fixture.lastQuestionResult?["answer"] is NSNull)
            #expect(fixture.lastQuestionResult?["cancelled"] as? Bool == true)
            #expect(!fixture.requestsContain("迟到回答不能触发交付"))
            #expect(!FileManager.default.fileExists(atPath: fixture.report.path))
            #expect(try fixture.receipts().isEmpty)
            #expect(model.currentTask?.phase == .needsReview)
            try await model.shutdownAndWait()
        } catch { try? await model.shutdownAndWait(); fixture.stop(); throw error }
        fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingWhileQuestionWaitsRevokesItsAnswerContinuation() async throws {
        let fixture = try await HTTPModelFixture.start()
        let model = fixture.makeModel(MemoryCredentialStore())
        do {
            await model.connect()
            try await configure(model, fixture)
            model.settings.proactive = false
            model.draft = "ask-stop-question"
            model.sendPrompt()
            try await eventually("question before task stop") { model.pendingQuestion != nil }
            model.stop()
            model.answerQuestion("停止后的迟到回答")
            #expect(model.pendingQuestion == nil)
            #expect(!model.isBusy)
            #expect(model.currentTask?.phase == .paused)
            try await model.shutdownAndWait()
            #expect(model.pendingPermission == nil)
            #expect(!fixture.requestsContain("停止后的迟到回答"))
            #expect(!FileManager.default.fileExists(atPath: fixture.report.path))
            #expect(try fixture.receipts().isEmpty)
        } catch { try? await model.shutdownAndWait(); fixture.stop(); throw error }
        fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitResumeAfterHTTPFailureKeepsThreadDraftAndOriginalPrompt() async throws {
        let fixture = try await HTTPModelFixture.start()
        let model = fixture.makeModel(MemoryCredentialStore())
        do {
            await model.connect()
            try await configure(model, fixture)
            model.settings.proactive = false
            model.draft = "resume-after-http-failure"
            model.sendPrompt()
            try await eventually("fixture HTTP failure") { !model.isBusy }
            #expect(model.currentTask?.phase == .failed)
            let thread = try #require(model.currentTask?.engineID)
            model.draft = "保留这条未发送草稿"
            #expect(model.canResumeTask)
            model.resumeTask()
            try await eventually("resumed task's file approval") { model.pendingPermission != nil }
            #expect(model.currentTask?.engineID == thread)
            #expect(model.draft == "保留这条未发送草稿")
            model.respondPermission(true)
            try await eventually("explicit resume completes actual delivery") { !model.isBusy }
            #expect(model.currentTask?.phase == .completed)
            #expect(model.currentTask?.engineID == thread)
            #expect(model.draft == "保留这条未发送草稿")
            expectSingleOriginalPrompt(model, fixture, draft: "保留这条未发送草稿")
            #expect(try String(contentsOf: fixture.report, encoding: .utf8) == "你好，后端实际写入。\n")
            #expect(try fixture.receipts().count == 1)
            try await model.shutdownAndWait()
        } catch { try? await model.shutdownAndWait(); fixture.stop(); throw error }
        fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedTaskCanReopenAndResumeWithoutSendingOriginalPromptOrDraftAgain() async throws {
        let fixture = try await HTTPModelFixture.start()
        let secrets = MemoryCredentialStore()
        let model = fixture.makeModel(secrets)
        var reopened: AppModel?
        do {
            await model.connect()
            try await configure(model, fixture)
            model.settings.proactive = false
            model.draft = "resume-after-http-failure"
            model.sendPrompt()
            try await eventually("HTTP failure before reopening") { !model.isBusy }
            #expect(model.currentTask?.phase == .failed)
            let task = try #require(model.selectedTaskID)
            let thread = try #require(model.currentTask?.engineID)
            model.draft = "重开后仍需保留的未发送草稿"
            try await model.shutdownAndWait()

            let restored = fixture.makeModel(secrets)
            reopened = restored
            await restored.connect()
            #expect(restored.selectedTaskID == task)
            #expect(restored.currentTask?.engineID == thread)
            #expect(restored.draft == "重开后仍需保留的未发送草稿")
            #expect(restored.canResumeTask)
            restored.resumeTask()
            try await eventually("reopened task's approval") { restored.pendingPermission != nil }
            restored.respondPermission(true)
            try await eventually("reopened task delivers and verifies") { !restored.isBusy }
            #expect(restored.currentTask?.phase == .completed)
            #expect(restored.currentTask?.engineID == thread)
            #expect(restored.draft == "重开后仍需保留的未发送草稿")
            expectSingleOriginalPrompt(restored, fixture, draft: "重开后仍需保留的未发送草稿")
            #expect(try fixture.receipts().count == 1)
            try await restored.shutdownAndWait()
        } catch {
            try? await model.shutdownAndWait()
            if let reopened { try? await reopened.shutdownAndWait() }
            fixture.stop()
            throw error
        }
        fixture.stop()
    }

    private func expectSingleOriginalPrompt(_ model: AppModel, _ fixture: HTTPModelFixture, draft: String) {
        #expect(model.currentTask?.messages.filter { $0.role == "user" && $0.text == "resume-after-http-failure" }.count == 1)
        #expect(!fixture.requestsContain(draft))
        for request in fixture.requests {
            let messages = request["messages"] as? [[String: Any]] ?? []
            #expect(messages.filter { $0["role"] as? String == "user" && $0["content"] as? String == "resume-after-http-failure" }.count == 1)
        }
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
private final class RejectingCredentialStore: CredentialStore {
    private(set) var operations: [String] = []
    func read(_ account: String, allowInteraction: Bool) throws -> String? {
        operations.append("read")
        throw AppFailure.message("No-key test forbids CredentialStore reads")
    }
    func save(_ secret: String, account: String) throws {
        operations.append("save")
        throw AppFailure.message("No-key test forbids CredentialStore writes")
    }
    func remove(_ account: String) throws {
        operations.append("remove")
        throw AppFailure.message("No-key test forbids CredentialStore deletes")
    }
}

@MainActor
private final class GateableCredentialStore: CredentialStore {
    var rejectReads = false
    private(set) var values: [String: String] = [:]
    private(set) var operations: [String] = []
    func read(_ account: String, allowInteraction: Bool) throws -> String? {
        operations.append("read")
        if rejectReads { throw AppFailure.message("Previous provider Keychain read is forbidden in local no-key mode") }
        return values[account]
    }
    func save(_ secret: String, account: String) throws {
        operations.append("save")
        values[account] = secret
    }
    func remove(_ account: String) throws {
        operations.append("remove")
        values.removeValue(forKey: account)
    }
}

@MainActor
private final class HTTPModelFixture {
    static let key = "myagent-e2e-fixture-key-not-a-real-credential"
    let directory: URL
    let process = Process()
    private var diagnosticHandle: FileHandle?
    var address = ""
    var data: URL { directory.appendingPathComponent("data") }
    var report: URL { data.appendingPathComponent("Workspace/deliverables/report.txt") }
    var provider: ProviderDraft { ProviderDraft(kind: "custom", baseURL: address, model: "fixture-agent") }
    var requestCount: Int { ((try? Data(contentsOf: directory.appendingPathComponent("requests.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? Int }) ?? 0 }
    var requests: [[String: Any]] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("request-bodies.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let bytes = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
    }
    var httpRequests: [[String: Any]] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("http-requests.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let bytes = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
    }
    var lastQuestionResult: [String: Any]? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("question-result.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    func requestsContain(_ text: String) -> Bool {
        requests.contains { request in
            guard let data = try? JSONSerialization.data(withJSONObject: request) else { return false }
            return String(decoding: data, as: UTF8.self).contains(text)
        }
    }

    private init(allowUnauthenticated: Bool) throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("myagent-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if allowUnauthenticated {
            try Data().write(to: directory.appendingPathComponent("allow-unauthenticated-local-fixture"))
        }
        let script = directory.appendingPathComponent("model.py")
        try Data(Self.source.utf8).write(to: script)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, directory.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        let diagnostics = directory.appendingPathComponent("fixture-stderr.log")
        guard FileManager.default.createFile(atPath: diagnostics.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AppFailure.message("Unable to create isolated HTTP fixture diagnostics")
        }
        diagnosticHandle = try FileHandle(forWritingTo: diagnostics)
        process.standardError = diagnosticHandle
        do { try process.run() }
        catch {
            try? diagnosticHandle?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func start(allowUnauthenticated: Bool = false) async throws -> HTTPModelFixture {
        let fixture = try HTTPModelFixture(allowUnauthenticated: allowUnauthenticated)
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while true {
            guard fixture.process.isRunning else {
                let failure = fixture.startupFailure("exited before readiness (status \(fixture.process.terminationStatus))")
                fixture.stop()
                throw failure
            }
            if let text = try? String(contentsOf: fixture.directory.appendingPathComponent("address.txt"), encoding: .utf8),
               let address = URL(string: text), address.scheme == "http", address.host == "127.0.0.1",
               address.port != nil, address.path == "/v1" {
                fixture.address = text
                return fixture
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                let failure = fixture.startupFailure("readiness handshake timed out after 20 seconds while the process was still running")
                fixture.stop()
                throw failure
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func startupFailure(_ reason: String) -> AppFailure {
        // This file belongs exclusively to the environment-cleared Python
        // fixture. Never read application, provider, or Keychain diagnostics.
        let file = directory.appendingPathComponent("fixture-stderr.log")
        var diagnostic = "No fixture stderr was captured."
        if let reader = try? FileHandle(forReadingFrom: file) {
            defer { try? reader.close() }
            if let size = try? reader.seekToEnd() {
                try? reader.seek(toOffset: size > 4_096 ? size - 4_096 : 0)
                if let bytes = try? reader.read(upToCount: 4_096), !bytes.isEmpty {
                    diagnostic = String(decoding: bytes, as: UTF8.self)
                        .replacingOccurrences(of: Self.key, with: "[fixture key redacted]")
                }
            }
        }
        return AppFailure.message("HTTP model fixture \(reason).\nFixture stderr (last 4 KB):\n\(diagnostic)")
    }

    func makeModel(_ secrets: any CredentialStore) -> AppModel {
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
        try? diagnosticHandle?.close()
        diagnosticHandle = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private static let source = #"""
    import http.server, json, pathlib, sys
    root = pathlib.Path(sys.argv[1]); count = 0
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def authenticate(self):
            actual = self.headers.get('Authorization')
            with (root/'http-requests.jsonl').open('a') as log:
                log.write(json.dumps({'method':self.command,'path':self.path,'authorizationPresent':actual is not None})+'\n')
            no_key = (root/'allow-unauthenticated-local-fixture').exists()
            accepted = actual is None if no_key else actual == 'Bearer myagent-e2e-fixture-key-not-a-real-credential'
            if not accepted: self.send_error(401)
            return accepted
        def do_GET(self):
            if self.path != '/v1/models': self.send_error(404); return
            if not self.authenticate(): return
            data = json.dumps({'data':[{'id':'fixture-agent'}]}).encode()
            self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            global count
            if self.path != '/v1/chat/completions': self.send_error(404); return
            if not self.authenticate(): return
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert request['model'] == 'fixture-agent'
            names = {t['function']['name'] for t in request['tools']}
            assert {'write_file','read_file','complete_task'}.issubset(names)
            count += 1; (root/'requests.json').write_text(json.dumps(count))
            with (root/'request-bodies.jsonl').open('a') as log: log.write(json.dumps(request,ensure_ascii=False)+'\n')
            messages = request['messages']; user_index = max(i for i,m in enumerate(messages) if m['role']=='user')
            mode = messages[user_index]['content']; results = [m for m in messages[user_index+1:] if m['role']=='tool']; stage=len(results)
            scenario = next(m['content'] for m in messages if m['role']=='user')
            if scenario == 'resume-after-http-failure' and not (root/'failed-once').exists():
                (root/'failed-once').touch()
                body = json.dumps({'error':{'message':'isolated fixture transient failure'}}).encode()
                self.send_response(500); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body); return
            def tool_value(message):
                value = json.loads(message['content'])
                if isinstance(value,dict) and 'contentItems' in value:
                    assert value.get('success') is True
                    return json.loads(next(item['text'] for item in value['contentItems'] if item['type']=='inputText'))
                return value
            call = None; text = ''
            expected = '你好，后端实际写入。\n'
            asking = scenario in ('ask-open-question','ask-cancel-question','ask-stop-question')
            if asking and stage == 0:
                assert 'ask_user' in names
                call = ('ask_user', {'question':'这份报告应该写给谁？','context':'需要称呼来生成报告。','placeholder':'例如：开发团队'})
            elif asking and scenario in ('ask-cancel-question','ask-stop-question'):
                answer = tool_value(results[0]); (root/'question-result.json').write_text(json.dumps(answer,ensure_ascii=False))
                assert answer.get('answer') is None and answer.get('cancelled') is True
                text = '已取消提问，未继续交付。'
            elif mode == 'deny-write':
                if stage < 2: call = ('write_file', {'path':'deliverables/report.txt','content':'你好，后端实际写入。\n'})
                else: text = '用户拒绝，未写入文件。'
            else:
                if asking:
                    answer = tool_value(results[0]); (root/'question-result.json').write_text(json.dumps(answer,ensure_ascii=False))
                    assert answer == {'answer':'开发团队','cancelled':False}
                    expected = '致'+answer['answer']+'：你好，后端实际写入。\n'
                    stage -= 1
                if stage == 0: call = ('write_file', {'path':'deliverables/report.txt','content':expected})
                elif stage == 1: call = ('read_file', {'path':'deliverables/report.txt'})
                elif stage == 2:
                    actual = json.loads(results[-1]['content'])
                    assert actual['content'] == expected
                    call = ('complete_task', {'summary':'真实后端已写入并读回项目文件','artifacts':['deliverables/report.txt'],'verification':['read_file 实际返回预期的中文文件内容']})
                else: text = '已根据回答写入、读回并验收。' if asking else '已写入、读回并验收。'
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
