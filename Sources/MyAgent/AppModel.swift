import SwiftUI
import AppKit

/// The independent application's orchestration layer. No state belongs to an installed Codex/Qoder.
@MainActor
final class AppModel: ObservableObject {
    @Published var tasks: [AgentTask] = []
    @Published var selectedTaskID: UUID?
    @Published var draft = "" { didSet { scheduleDraftSave() } }
    @Published var models: [ModelOption] = []
    @Published var settings = AppSettings()
    @Published var accountLabel = "尚未配置模型"
    @Published var connectionLabel = "本地后端未连接"
    @Published var isConnected = false
    @Published var authInProgress = false
    @Published var providerDraft = ProviderDraft()
    @Published var apiKeyDraft = ""
    @Published var connectionTestStatus = ""
    @Published var isTestingConnection = false
    @Published var showConnectionSetup = false
    @Published var hasCredentials = false
    @Published var lastError: String?
    @Published var activities: [ActivityEntry] = []
    @Published var artifacts: [ArtifactItem] = []
    @Published var pendingPermission: PendingPermission?
    @Published var pendingChoice: PendingChoice?
    @Published var browserTitle = "独立浏览器尚未打开"
    @Published var browserImage: NSImage?
    @Published var desktopStatus = "未请求辅助功能权限"
    @Published var activeControlScope: String?
    @Published var previewTitle = ""
    @Published var previewText = ""
    @Published var previewImage: NSImage?
    @Published var showPreview = false
    @Published private var activeTaskID: UUID?

    let dataDirectory: URL
    private let engineHome: URL
    private let defaultWorkspace: URL
    private let stateFile: URL
    private let engineBinaryOverride: URL?
    private let connection = AgentConnection()
    private let browser = NativeBrowser()
    private let desktop = NativeDesktop()
    private var connecting = false
    private var authenticated = false
    private var savedProvider = ProviderDraft()
    private var taskDrafts: [UUID: String] = [:]
    private var stateRevision: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    private var draftSaveTask: Task<Void, Never>?
    private var turnID: String?
    private var turnStartTicket = UUID()
    private var startingTurn = false
    private var deferredEvents: [(String, [String: Any])] = []
    private var deferredRequests: [(Any, String, [String: Any])] = []
    private var runGeneration = UUID()
    private var streamingMessages: [String: UUID] = [:]
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var permissionReply: ((Bool) -> Void)?
    private var choiceReply: ((String?) -> Void)?
    private var leases: [String: Date] = [:]
    private var leaseTimer: Task<Void, Never>?
    private var completionAccepted = false
    private var completionReview: String?
    private var resumedThreads = Set<String>()

    var currentTask: AgentTask? { tasks.first { $0.id == selectedTaskID } }
    var isBusy: Bool { activeTaskID != nil }
    var canRun: Bool { isConnected && hasCredentials }
    var workspacePath: String { currentTask?.workspace ?? defaultWorkspace.path }

    init(dataDirectory: URL? = nil, engineBinary: URL? = nil) {
        let root = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyAgent", isDirectory: true)
        self.dataDirectory = root
        engineBinaryOverride = engineBinary
        engineHome = root.appendingPathComponent("engine", isDirectory: true)
        defaultWorkspace = root.appendingPathComponent("Workspace", isDirectory: true)
        stateFile = root.appendingPathComponent("state.json")
        do {
            for directory in [root, engineHome, defaultWorkspace] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            if FileManager.default.fileExists(atPath: stateFile.path) {
                let state = try JSONDecoder().decode(PersistedAppState.self, from: Data(contentsOf: stateFile))
                tasks = state.tasks.map { task in
                    var recovered = task
                    if [.running, .waiting, .connecting].contains(task.phase) { recovered.phase = .paused }
                    return recovered
                }
                selectedTaskID = state.selectedTaskID
                settings = state.settings
                if let provider = state.provider { providerDraft = provider; savedProvider = provider }
                draft = tasks.first(where: { $0.id == selectedTaskID })?.draft ?? state.unassignedDraft ?? ""
            }
        } catch { lastError = "无法载入应用数据：\(error.localizedDescription)" }
        connection.onEvent = { [weak self] method, params in self?.receiveEvent(method, params) }
        connection.onServerRequest = { [weak self] id, method, params in self?.receiveRequest(id, method, params) }
        connection.onClosed = { [weak self] reason in
            guard let self else { return }
            self.isConnected = false
            self.hasCredentials = false
            self.authenticated = false
            self.connectionLabel = "连接已中断"
            self.stop()
            self.lastError = reason
        }
        browser.onSnapshot = { [weak self] image, title in
            self?.browserImage = image
            self?.browserTitle = title
        }
        desktopStatus = desktop.status
        refreshArtifacts()
    }

    func connect() async {
        guard !isConnected, !connecting else { return }
        connecting = true
        let initialSelection = selectedTaskID
        let initialDraft = draft
        connectionLabel = "正在启动本地后端"
        defer { connecting = false }
        do {
            let binary: URL
            if let override = engineBinaryOverride {
                binary = override
            } else if let resource = Bundle.main.resourceURL,
               FileManager.default.isExecutableFile(atPath: resource.appendingPathComponent("backend/myagent-backend").path) {
                binary = resource.appendingPathComponent("backend/myagent-backend")
            } else {
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let release = root.appendingPathComponent("backend/target/release/myagent-backend")
                binary = FileManager.default.isExecutableFile(atPath: release.path) ? release : root.appendingPathComponent("backend/target/debug/myagent-backend")
            }
            try await connection.launch(binary: binary, home: engineHome)
            isConnected = true
            connectionLabel = "本地后端已连接"
            if engineBinaryOverride == nil {
                let stored = try await connection.call("app/state/read")
                if let revision = stored["revision"] as? NSNumber { stateRevision = max(stateRevision, revision.int64Value) }
                if let object = stored["state"] as? [String: Any], JSONSerialization.isValidJSONObject(object) {
                    let data = try JSONSerialization.data(withJSONObject: object)
                    if let state = try? JSONDecoder().decode(PersistedAppState.self, from: data) {
                        let recovered = state.tasks.map { task in
                            var recovered = task
                            if [.running, .connecting, .waiting].contains(task.phase) { recovered.phase = .paused }
                            return recovered
                        }
                        if selectedTaskID == initialSelection && draft == initialDraft {
                            tasks = recovered
                            settings = state.settings
                            selectedTaskID = state.selectedTaskID
                            if let provider = state.provider { providerDraft = provider; savedProvider = provider }
                            draft = tasks.first(where: { $0.id == selectedTaskID })?.draft ?? state.unassignedDraft ?? ""
                        } else {
                            // Loading the backend must not replace text already typed during startup.
                            let localIDs = Set(tasks.map(\.id))
                            tasks.append(contentsOf: recovered.filter { !localIDs.contains($0.id) })
                        }
                    }
                }
                if let key = try SecureStore.read(credentialAccount(savedProvider)) {
                    _ = try await connection.call("provider/configure", params: providerParameters(savedProvider, key: key))
                }
            }
            await refreshAccount()
            await refreshModels()
            if !hasCredentials && engineBinaryOverride == nil { showConnectionSetup = true; connectionLabel = "本地后端就绪 · 请配置模型" }
            log("本地后端已就绪", "任务和执行记录保存在本机 SQLite 数据库。")
            persist()
        } catch {
            lastError = error.localizedDescription
            if !isConnected { connectionLabel = "启动失败" }
        }
    }

    func reconnect() async {
        stop()
        connection.stop()
        isConnected = false
        resumedThreads.removeAll()
        await connect()
    }

    private func refreshAccount() async {
        do {
            let result = try await connection.call("account/read")
            if let account = result["account"] as? [String: Any] {
                authenticated = true
                hasCredentials = true
                accountLabel = account["email"] as? String ?? "模型已配置"
            } else {
                authenticated = false
                hasCredentials = false
                accountLabel = "尚未配置模型"
            }
        } catch { lastError = error.localizedDescription }
    }

    func login() { showConnectionSetup = true }
    func cancelLogin() { showConnectionSetup = false }

    private func credentialAccount(_ provider: ProviderDraft) -> String {
        provider.kind + "|" + provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func providerParameters(_ provider: ProviderDraft, key: String) -> [String: Any] {
        ["provider": provider.kind, "baseUrl": provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), "model": provider.model.trimmingCharacters(in: .whitespacesAndNewlines), "apiKey": key]
    }

    private func keyForDraft(_ provider: ProviderDraft, enteredKey: String) throws -> String {
        let entered = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        if let stored = try SecureStore.read(credentialAccount(provider)), !stored.isEmpty { return stored }
        throw AppFailure.message("请填写此模型服务的 API Key。密钥仅保存到 macOS 钥匙串。")
    }

    func testConnection() { performConnection(save: false) }
    func saveConnection() { performConnection(save: true) }

    private func performConnection(save: Bool) {
        guard !isTestingConnection, !isBusy else { return }
        isTestingConnection = true
        connectionTestStatus = "正在连接模型服务…"
        let candidate = providerDraft
        let enteredKey = apiKeyDraft
        Task {
            defer { isTestingConnection = false }
            do {
                if !isConnected {
                    if connecting { throw AppFailure.message("本地后端正在启动，请稍候再试。") }
                    await connect()
                }
                guard isConnected else { throw AppFailure.message("本地后端未启动，请先重新连接。") }
                let key = try keyForDraft(candidate, enteredKey: enteredKey)
                let result = try await connection.call("provider/test", params: providerParameters(candidate, key: key))
                guard result["reachable"] as? Bool == true else { throw AppFailure.message("模型服务尚未通过连接检查。") }
                let rows = result["models"] as? [[String: Any]] ?? []
                let ids = rows.compactMap { $0["id"] as? String }
                models = ids.map { ModelOption(id: $0, displayName: $0, isDefault: $0 == candidate.model) }
                connectionTestStatus = "连接成功，可用模型 \(ids.count) 个。"
                if save {
                    if !ids.isEmpty && !ids.contains(candidate.model.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        throw AppFailure.message("服务已连接，但模型列表中没有“\(candidate.model)”。请填写返回的实际模型 ID。")
                    }
                    _ = try await connection.call("provider/configure", params: providerParameters(candidate, key: key))
                    try SecureStore.save(key, account: credentialAccount(candidate))
                    var normalized = candidate
                    normalized.baseURL = candidate.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    normalized.model = candidate.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    savedProvider = normalized
                    providerDraft = normalized
                    settings.model = normalized.model
                    apiKeyDraft = ""
                    await refreshAccount()
                    connectionLabel = "本地后端已连接"
                    showConnectionSetup = false
                    persist()
                    log("模型连接已保存", "\(candidate.kind) · \(candidate.model)。密钥在本机钥匙串中。")
                }
            } catch {
                connectionTestStatus = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    func disconnectProvider() {
        guard !isBusy else { lastError = "请先停止正在执行的任务。"; return }
        do { try SecureStore.remove(credentialAccount(savedProvider)) }
        catch { lastError = error.localizedDescription; return }
        hasCredentials = false
        authenticated = false
        apiKeyDraft = ""
        accountLabel = "尚未配置模型"
        Task { await reconnect() }
    }

    private func refreshModels() async {
        do {
            let result = try await connection.call("model/list")
            models = (result["data"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["model"] as? String ?? row["id"] as? String else { return nil }
                return ModelOption(id: id, displayName: row["displayName"] as? String ?? id, isDefault: row["isDefault"] as? Bool ?? false)
            }
        } catch { lastError = "模型列表暂不可用：\(error.localizedDescription)" }
    }

    func newTask() {
        if let selectedTaskID {
            taskDrafts[selectedTaskID] = draft
            if let i = tasks.firstIndex(where: { $0.id == selectedTaskID }) { tasks[i].draft = draft }
        }
        let project = currentTask?.workspace ?? defaultWorkspace.path
        let task = AgentTask(title: "新任务", workspace: project)
        tasks.insert(task, at: 0)
        selectedTaskID = task.id
        draft = ""
        refreshArtifacts()
        persist()
    }

    func selectTask(_ id: UUID) {
        if let selectedTaskID {
            taskDrafts[selectedTaskID] = draft
            if let i = tasks.firstIndex(where: { $0.id == selectedTaskID }) { tasks[i].draft = draft }
        }
        selectedTaskID = id
        draft = taskDrafts[id] ?? tasks.first(where: { $0.id == id })?.draft ?? ""
        refreshArtifacts(); persist()
    }

    func chooseWorkspace() {
        guard !isBusy else { lastError = "请先停止当前任务，再更换项目。"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择项目"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if currentTask == nil { newTask() }
        guard let index = tasks.firstIndex(where: { $0.id == selectedTaskID }) else { return }
        // A running engine thread's sandbox cannot silently move between projects.
        if tasks[index].engineID != nil {
            let task = AgentTask(title: url.lastPathComponent, workspace: url.path)
            tasks.insert(task, at: 0)
            selectedTaskID = task.id
        } else { tasks[index].workspace = url.path }
        refreshArtifacts()
        persist()
    }

    func sendPrompt() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy else { return }
        guard authenticated else { showConnectionSetup = true; return }
        guard isConnected else { lastError = "Agent 运行时尚未连接。"; return }
        if currentTask == nil { newTask() }
        guard let id = selectedTaskID, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if tasks[index].messages.isEmpty { tasks[index].title = String(prompt.prefix(30)) }
        tasks[index].messages.append(ChatEntry(role: "user", text: prompt))
        tasks[index].automaticRounds = 0
        tasks[index].updatedAt = Date()
        draft = ""
        taskDrafts[id] = ""
        tasks[index].draft = nil
        activeTaskID = id
        runGeneration = UUID()
        let generation = runGeneration
        completionAccepted = false
        completionReview = nil
        persist()
        Task { await startTurn(taskID: id, text: prompt, generation: generation) }
    }

    private func startTurn(taskID: UUID, text: String, generation: UUID) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), generation == runGeneration else { return }
        let ticket = UUID()
        turnStartTicket = ticket
        tasks[index].phase = .connecting
        do {
            var threadID = tasks[index].engineID
            if threadID == nil {
                var params: [String: Any] = ["cwd": tasks[index].workspace, "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "workspace-write", "dynamicTools": Self.dynamicTools, "developerInstructions": Self.instructions]
                if let model = settings.model, !model.isEmpty { params["model"] = model }
                let result = try await connection.call("thread/start", params: params)
                threadID = (result["thread"] as? [String: Any])?["id"] as? String
                guard let threadID else { throw AppFailure.message("运行时未创建任务。") }
                guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
                tasks[i].engineID = threadID
                resumedThreads.insert(threadID)
            } else if let existing = threadID, !resumedThreads.contains(existing) {
                var resume: [String: Any] = ["threadId": existing, "cwd": tasks[index].workspace, "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "workspace-write"]
                if let model = settings.model, !model.isEmpty { resume["model"] = model }
                _ = try await connection.call("thread/resume", params: resume)
                resumedThreads.insert(existing)
            }
            guard generation == runGeneration, let threadID else { return }
            startingTurn = true
            var turnParams: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text]]]
            if let model = settings.model, !model.isEmpty { turnParams["model"] = model }
            let result = try await connection.call("turn/start", params: turnParams)
            let newTurnID = (result["turn"] as? [String: Any])?["id"] as? String
            guard generation == runGeneration else {
                if let newTurnID { _ = try? await connection.call("turn/interrupt", params: ["threadId": threadID, "turnId": newTurnID]) }
                return
            }
            // Events may finish this turn and start a follow-up before the RPC reply arrives.
            guard ticket == turnStartTicket, activeTaskID == taskID else { return }
            turnID = newTurnID
            startingTurn = false
            setPhase(.running, taskID)
            let events = deferredEvents
            let requests = deferredRequests
            deferredEvents.removeAll()
            deferredRequests.removeAll()
            for (method, params) in events { receiveEvent(method, params) }
            for (id, method, params) in requests { receiveRequest(id, method, params) }
            persist()
        } catch {
            guard generation == runGeneration else { return }
            startingTurn = false
            deferredEvents.removeAll()
            for (id, _, _) in deferredRequests { connection.respondError(id: id, message: "Turn failed to start.") }
            deferredRequests.removeAll()
            setPhase(.failed, taskID)
            activeTaskID = nil
            lastError = error.localizedDescription
            persist()
        }
    }

    func stop() {
        let active = activeTaskID
        let thread = tasks.first { $0.id == active }?.engineID
        let turn = turnID
        runGeneration = UUID()
        turnStartTicket = UUID()
        startingTurn = false
        deferredEvents.removeAll()
        for (id, _, _) in deferredRequests { connection.respondError(id: id, message: "Task was stopped.") }
        deferredRequests.removeAll()
        for task in toolTasks.values { task.cancel() }
        toolTasks.removeAll()
        browser.stop()
        desktop.stop()
        leases.removeAll()
        leaseTimer?.cancel()
        activeControlScope = nil
        respondPermission(false)
        declineChoice()
        if let active { setPhase(.paused, active); log("任务已停止", "后续工具动作与控制授权已撤销。") }
        activeTaskID = nil
        turnID = nil
        if let thread, let turn { Task { _ = try? await connection.call("turn/interrupt", params: ["threadId": thread, "turnId": turn]) } }
        persist()
    }

    private func receiveEvent(_ method: String, _ params: [String: Any]) {
        if method == "account/updated" { Task { await refreshAccount() }; return }
        guard let id = activeTaskID,
              let taskIndex = tasks.firstIndex(where: { $0.id == id }),
              params["threadId"] as? String == tasks[taskIndex].engineID else { return }
        if startingTurn {
            guard deferredEvents.count < 256 else { stop(); lastError = "启动期间事件积压超限，已停止。"; return }
            deferredEvents.append((method, params))
            return
        }
        let incomingTurn = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
        guard let currentTurnID = turnID, incomingTurn == nil || incomingTurn == currentTurnID else { return }
        switch method {
        case "turn/started":
            setPhase(.running, id)
        case "item/agentMessage/delta":
            updateAgentMessage(taskID: id, itemID: params["itemId"] as? String ?? UUID().uuidString, text: params["delta"] as? String ?? "", replace: false)
        case "item/started":
            if let item = params["item"] as? [String: Any], let type = item["type"] as? String, type != "agentMessage" {
                log(Self.itemLabel(type), item["command"] as? String ?? "Agent 正在执行。")
            }
        case "item/completed":
            if let item = params["item"] as? [String: Any] {
                if item["type"] as? String == "agentMessage" {
                    updateAgentMessage(taskID: id, itemID: item["id"] as? String ?? UUID().uuidString, text: item["text"] as? String ?? "", replace: true)
                } else { refreshArtifacts() }
            }
        case "turn/plan/updated":
            let lines = (params["plan"] as? [[String: Any]] ?? []).map { "\($0["status"] as? String ?? "") · \($0["step"] as? String ?? "")" }
            if !lines.isEmpty { log("执行计划", lines.joined(separator: "\n")) }
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any] else { return }
            if let completedID = turn["id"] as? String, completedID != currentTurnID { return }
            handleTurnCompleted(turn, taskID: id)
        case "error":
            let error = params["error"] as? [String: Any]
            lastError = error?["message"] as? String ?? "Agent 遇到错误。"
        default: break
        }
    }

    private func handleTurnCompleted(_ turn: [String: Any], taskID: UUID) {
        turnStartTicket = UUID()
        turnID = nil
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let status = turn["status"] as? String ?? "failed"
        if status == "completed", !completionAccepted, settings.proactive, tasks[i].automaticRounds < max(0, min(3, settings.maxAutomaticRounds)) {
            tasks[i].automaticRounds += 1
            let generation = runGeneration
            log("主动检查 \(tasks[i].automaticRounds)", "核对交付物和验收依据，最多 \(settings.maxAutomaticRounds) 轮。")
            let text = "继续完成已授权的任务闭环。检查实际文件与验证结果；若已经完成，调用 complete_task 并给出真实验收依据。若需要用户决定，调用 present_choices，准备可预览的文件。不要为了闭环编造结果；若只是问答，可以用无文件的验收说明完成。\(completionReview.map { " 上次验收问题：\($0)" } ?? "")"
            Task { await startTurn(taskID: taskID, text: text, generation: generation) }
        } else {
            tasks[i].phase = status == "interrupted" ? .paused : status == "completed" ? .completed : .failed
            if status == "failed" {
                lastError = (turn["error"] as? [String: Any])?["message"] as? String ?? "本轮执行失败。"
                if lastError?.contains("401") == true { showConnectionSetup = true }
            }
            if status == "completed" && !completionAccepted {
                tasks[i].phase = .needsReview
                log("本轮已结束，验收待确认", "主动检查次数已用完或已关闭；未收到有效验收回执。")
            }
            activeTaskID = nil
            revokeControls()
        }
        refreshArtifacts()
        persist()
    }

    private func updateAgentMessage(taskID: UUID, itemID: String, text: String, replace: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if let messageID = streamingMessages[itemID], let j = tasks[i].messages.firstIndex(where: { $0.id == messageID }) {
            if replace { tasks[i].messages[j].text = text } else { tasks[i].messages[j].text += text }
        } else {
            let entry = ChatEntry(role: "assistant", text: text)
            streamingMessages[itemID] = entry.id
            tasks[i].messages.append(entry)
        }
        tasks[i].updatedAt = Date()
    }

    private func receiveRequest(_ id: Any, _ method: String, _ params: [String: Any]) {
        guard let active = activeTaskID, let task = tasks.first(where: { $0.id == active }), params["threadId"] as? String == task.engineID else {
            connection.respondError(id: id, message: "No active authorized task.")
            return
        }
        if startingTurn {
            guard deferredRequests.count < 16 else { connection.respondError(id: id, message: "Too many requests while starting."); return }
            deferredRequests.append((id, method, params))
            return
        }
        guard let turnID, params["turnId"] as? String == turnID else {
            connection.respondError(id: id, message: "Request belongs to an inactive turn.")
            return
        }
        let key = String(describing: id)
        let generation = runGeneration
        toolTasks[key] = Task {
            defer { toolTasks.removeValue(forKey: key) }
            if method == "item/tool/call" {
                do {
                    let name = params["tool"] as? String ?? ""
                    var args = params["arguments"] as? [String: Any] ?? [:]
                    if let string = params["arguments"] as? String, let data = string.data(using: .utf8), let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] { args = decoded }
                    let value = try await runTool(name, args: args, task: task, generation: generation)
                    try ensureRunning(generation)
                    replyTool(id, value, success: true)
                } catch { replyTool(id, ["error": error.localizedDescription], success: false) }
            } else if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                let allowed = await askPermission(title: method.contains("command") ? "允许执行这条命令？" : "允许修改这些文件？", detail: "\(params["command"] as? String ?? params["reason"] as? String ?? "当前项目的操作需要批准")\n目录：\(params["cwd"] as? String ?? task.workspace)", scope: "仅这一次操作", kind: "execution")
                connection.respond(id: id, result: ["decision": allowed && generation == runGeneration ? "accept" : "decline"])
            } else if method == "item/tool/requestUserInput" {
                var answers: [String: Any] = [:]
                for question in params["questions"] as? [[String: Any]] ?? [] {
                    let options = (question["options"] as? [[String: Any]] ?? []).enumerated().map { index, option in
                        ChoiceCard(id: String(index), title: option["label"] as? String ?? "选项", description: option["description"] as? String ?? "", deliverables: [], previewPaths: [], impact: "", nextStep: "按此选项继续")
                    }
                    guard !options.isEmpty else { connection.respondError(id: id, message: "Free text input is not supported by this client yet. Ask in chat."); return }
                    let chosen = await askChoice(PendingChoice(title: question["question"] as? String ?? "请选择", options: options))
                    let label = options.first { $0.id == chosen }?.title
                    answers[question["id"] as? String ?? "question"] = ["answers": label.map { [$0] } ?? []]
                }
                connection.respond(id: id, result: ["answers": answers])
            } else { connection.respondError(id: id, message: "Unsupported request: \(method)") }
        }
    }

    private func runTool(_ name: String, args: [String: Any], task: AgentTask, generation: UUID) async throws -> [String: Any] {
        try ensureRunning(generation)
        switch name {
        case "present_choices":
            let data = try JSONSerialization.data(withJSONObject: args["options"] ?? [])
            let choices = try JSONDecoder().decode([ChoiceCard].self, from: data)
            guard (2...4).contains(choices.count), Set(choices.map(\.id)).count == choices.count else { throw AppFailure.message("需提供 2–4 个不同的方案。") }
            for choice in choices { for path in choice.previewPaths { _ = try WorkspacePaths.confinedFile(path, workspace: task.workspace) } }
            let answer = await askChoice(PendingChoice(title: args["title"] as? String ?? "选择下一步", options: choices))
            try ensureRunning(generation)
            return ["chosen": answer as Any? ?? NSNull(), "cancelled": answer == nil]
        case "browser":
            let action = args["action"] as? String ?? "read"
            let origin: String
            if action == "open", let text = args["url"] as? String {
                let url = try NativeBrowser.validatedURL(text)
                guard let normalized = NativeBrowser.origin(for: url) else { throw AppFailure.message("无效的浏览器来源。") }
                origin = normalized
            } else if let current = browser.currentOrigin { origin = current }
            else { throw AppFailure.message("先提供 http/https 地址打开独立浏览器。") }
            try await requireLease("browser:\(origin)", title: "允许使用独立浏览器？", detail: "仅访问 \(origin)，授权 90 秒。使用独立临时会话，在后台运行；不会读取你现有浏览器的登录状态。", kind: "browser", generation: generation)
            let result = try await browser.perform(args, workspace: task.workspace)
            try ensureRunning(generation)
            browserTitle = browser.title
            log("独立浏览器 · \(action)", origin)
            refreshArtifacts()
            return result
        case "desktop":
            if args["action"] as? String == "list_apps" { return ["apps": desktop.listApps()] }
            guard let bundle = args["bundleId"] as? String, !bundle.isEmpty else { throw AppFailure.message("桌面操作需要指定目标应用 bundleId。") }
            try await requireLease("desktop:\(bundle)", title: "允许控制指定应用？", detail: "仅 \(bundle)，授权 90 秒。通过辅助功能定向读写；动作前等待你空闲 3 秒，20 秒内仍忙则暂停。不会模拟全局键鼠或自动切换前台。", kind: "desktop", generation: generation)
            let result = try await desktop.perform(args)
            try ensureRunning(generation)
            desktopStatus = desktop.status
            log("桌面 · \(args["action"] as? String ?? "")", bundle)
            return result
        case "complete_task":
            let summary = args["summary"] as? String ?? ""
            let evidence = args["verification"] as? [String] ?? []
            let paths = args["artifacts"] as? [String] ?? []
            guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !evidence.isEmpty, evidence.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                completionReview = "缺少完成说明或验收依据。"
                throw AppFailure.message(completionReview!)
            }
            var verified: [String] = []
            for path in paths { verified.append(try WorkspacePaths.confinedFile(path, workspace: task.workspace).path) }
            let receipt: [String: Any] = ["task": task.title, "summary": summary, "verification": evidence, "artifacts": verified, "time": ISO8601DateFormatter().string(from: Date()), "note": "文件存在性由应用检查；验收说明由 Agent 提供，应按具体任务复核。"]
            let directory = URL(fileURLWithPath: task.workspace).appendingPathComponent("deliverables")
            // Resolve the output directory as well, so a symlink cannot redirect receipts outside the project.
            let root = URL(fileURLWithPath: task.workspace).resolvingSymlinksInPath().path
            guard directory.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw AppFailure.message("交付目录超出了项目。") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("receipt-\(UUID().uuidString.prefix(8)).json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
            completionAccepted = true
            log("收到验收回执", summary)
            refreshArtifacts()
            return ["accepted": true, "receipt": file.path, "verifiedFiles": verified]
        default: throw AppFailure.message("未知工具：\(name)")
        }
    }

    private func requireLease(_ scope: String, title: String, detail: String, kind: String, generation: UUID) async throws {
        // Renew early enough that a bounded 20-second action cannot outlive its grant.
        if let until = leases[scope], until > Date().addingTimeInterval(25) { return }
        let allowed = await askPermission(title: title, detail: detail, scope: scope, kind: kind)
        try ensureRunning(generation)
        guard allowed else { throw AppFailure.message("用户未授权本次控制；请提供可在后台完成的下一步。") }
        leases[scope] = Date().addingTimeInterval(90)
        activeControlScope = "\(scope) · 90 秒内有效"
        leaseTimer?.cancel()
        leaseTimer = Task {
            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
            leases = leases.filter { $0.value > Date() }
            activeControlScope = leases.keys.sorted().joined(separator: " · ")
            if leases.isEmpty { activeControlScope = nil }
        }
    }

    private func askPermission(title: String, detail: String, scope: String, kind: String) async -> Bool {
        guard pendingPermission == nil, !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            let request = PendingPermission(title: title, detail: detail, scope: scope, kind: kind)
            pendingPermission = request
            permissionReply = { continuation.resume(returning: $0) }
            if !settings.quietMode { NSSound.beep() }
            if let activeTaskID { setPhase(.waiting, activeTaskID) }
            Task {
                do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                if pendingPermission?.id == request.id { respondPermission(false) }
            }
        }
    }

    func respondPermission(_ allowed: Bool) {
        let callback = permissionReply
        permissionReply = nil
        let valid = pendingPermission.map { $0.expiresAt > Date() } ?? false
        pendingPermission = nil
        if let activeTaskID { setPhase(.running, activeTaskID) }
        callback?(allowed && valid)
    }

    private func askChoice(_ choice: PendingChoice) async -> String? {
        guard pendingChoice == nil, !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            pendingChoice = choice
            choiceReply = { continuation.resume(returning: $0) }
            if !settings.quietMode { NSSound.beep() }
            if let activeTaskID { setPhase(.waiting, activeTaskID) }
        }
    }

    func chooseOption(_ id: String) {
        guard pendingChoice?.options.contains(where: { $0.id == id }) == true else { return }
        let callback = choiceReply
        pendingChoice = nil
        choiceReply = nil
        if let activeTaskID { setPhase(.running, activeTaskID) }
        callback?(id)
    }

    func declineChoice() {
        let callback = choiceReply
        pendingChoice = nil
        choiceReply = nil
        if let activeTaskID { setPhase(.running, activeTaskID) }
        callback?(nil)
    }

    func continueReview() {
        guard !isBusy, canRun, let id = selectedTaskID else { return }
        activeTaskID = id
        runGeneration = UUID()
        completionAccepted = false
        let generation = runGeneration
        Task { await startTurn(taskID: id, text: "继续核验此任务的交付物，补齐缺失工作，并用真实依据调用 complete_task。若无法完成，清楚说明需要我提供什么。", generation: generation) }
    }

    private func ensureRunning(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == runGeneration, activeTaskID != nil else { throw CancellationError() }
    }

    private func replyTool(_ id: Any, _ value: [String: Any], success: Bool) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        connection.respond(id: id, result: ["success": success, "contentItems": [["type": "inputText", "text": String(decoding: data, as: UTF8.self)]]])
    }

    private func revokeControls() {
        leases.removeAll()
        leaseTimer?.cancel()
        activeControlScope = nil
        browser.stop()
        desktop.stop()
    }

    func previewPath(_ path: String) {
        do {
            let previewWorkspace = pendingChoice != nil ? tasks.first(where: { $0.id == activeTaskID })?.workspace ?? workspacePath : workspacePath
            let url = try WorkspacePaths.confinedFile(path, workspace: previewWorkspace)
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= 8_000_000 else { throw AppFailure.message("文件超过预览上限，可在项目目录中打开。") }
            previewTitle = url.lastPathComponent
            previewImage = NSImage(contentsOf: url)
            previewText = previewImage == nil ? String((try String(contentsOf: url, encoding: .utf8)).prefix(40_000)) : ""
            showPreview = true
        } catch { lastError = error.localizedDescription }
    }

    func openProjectFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: workspacePath)) }
    func enableAccessibility() { desktop.requestAccessibility(); desktopStatus = desktop.status }
    func saveSettings() { settings.maxAutomaticRounds = max(0, min(3, settings.maxAutomaticRounds)); persist() }
    func clearError() { lastError = nil }

    private func setPhase(_ phase: RunPhase, _ id: UUID) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].phase = phase; tasks[i].updatedAt = Date() }
    }

    private func persist() {
        do {
            let state = PersistedAppState(selectedTaskID: selectedTaskID, tasks: tasks, settings: settings, provider: savedProvider, unassignedDraft: selectedTaskID == nil ? draft : nil)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
            if isConnected, engineBinaryOverride == nil, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                stateRevision = max(stateRevision + 1, Int64(Date().timeIntervalSince1970 * 1_000))
                let revision = stateRevision
                Task { _ = try? await connection.call("app/state/write", params: ["state": object, "revision": revision]) }
            }
        } catch { lastError = "无法保存任务：\(error.localizedDescription)" }
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let id = selectedTaskID
        let text = draft
        draftSaveTask = Task {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard selectedTaskID == id, draft == text else { return }
            if let id, let i = tasks.firstIndex(where: { $0.id == id }) {
                tasks[i].draft = text
                taskDrafts[id] = text
            }
            persist()
        }
    }

    private func log(_ title: String, _ detail: String) {
        activities.insert(ActivityEntry(title: title, detail: String(detail.prefix(5_000))), at: 0)
        if activities.count > 120 { activities.removeLast(activities.count - 120) }
    }

    private func refreshArtifacts() {
        let root = URL(fileURLWithPath: workspacePath)
        let skip = Set(["node_modules", ".git", ".build", ".engine", "vendor", "dist", "build"])
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { artifacts = []; return }
        var rows: [(Date, ArtifactItem)] = []
        var count = 0
        while let url = iterator.nextObject() as? URL {
            count += 1
            if count > 4_000 { break }
            if skip.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
            guard let info = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if info.isDirectory == true { continue }
            guard info.isRegularFile == true, (try? WorkspacePaths.confinedFile(url.path, workspace: root.path)) != nil else { continue }
            rows.append((info.contentModificationDate ?? .distantPast, ArtifactItem(name: url.lastPathComponent, path: url.path, bytes: info.fileSize ?? 0, kind: url.pathExtension)))
        }
        artifacts = rows.sorted { $0.0 > $1.0 }.prefix(80).map(\.1)
    }

    private static func itemLabel(_ type: String) -> String {
        switch type { case "commandExecution": return "执行命令"; case "fileChange": return "修改文件"; case "dynamicToolCall": return "调用应用工具"; case "reasoning": return "正在分析"; default: return type }
    }

    static let instructions = """
    You are the agent inside MyAgent, an independently maintained macOS application. Follow the user's language.
    Act toward actual deliverables and verify results. Before a consequential design choice, prepare 2–4 concrete alternatives with existing preview files where useful and call present_choices. Describe deliverables, office impact, and the next step. For routine reversible steps, continue autonomously within the user's request.
    Use the application's browser tool for isolated background web work, and desktop only for a user-authorized named app. Do not invoke AppleScript, osascript, global input synthesis, browser profile copying, or read another app's credentials to bypass these tools. Never request passwords, OTPs, or secret tokens via a tool. The user grants scoped control in the native UI and may stop at any time. Stop/denial is final for the action.
    Existing browser cookies are unavailable; request a next step if access requires login. Do not submit forms, send messages, spend money, or publish on behalf of the user without explicit authorization.
    Close the loop: perform the work, inspect outputs, run appropriate checks, then call complete_task with existing project-relative artifact paths, an honest summary, and specific verification evidence. A chat-only answer may supply no artifacts. The receipt records your evidence; it does not prove assertions. Do not claim tests or model runs that did not happen. If blocked, explain the exact missing input; do not manufacture completion.
    """

    static var dynamicTools: [[String: Any]] {
        func string(_ text: String) -> [String: Any] { ["type": "string", "description": text] }
        func array(_ text: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": text] }
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
        let choice: [String: Any] = ["type": "object", "properties": ["id": string("Unique option ID"), "title": string("Option title"), "description": string("What this does"), "deliverables": array("Concrete expected deliverables"), "previewPaths": array("Existing files inside the project, never invented"), "impact": string("Impact on the user's ongoing office work"), "nextStep": string("What happens if selected")], "required": ["id", "title", "description", "deliverables", "previewPaths", "impact", "nextStep"], "additionalProperties": false]
        return [
            tool("present_choices", "Present 2–4 inspectable alternatives in the native UI and wait for the user's choice.", ["title": string("Decision question"), "options": ["type": "array", "items": choice, "minItems": 2, "maxItems": 4]], ["title", "options"]),
            tool("browser", "Operate the app's isolated background browser after scoped native consent. Cannot use existing user cookies, submit forms, or cross origins without approval. read returns observed selectors; use them for click/fill.", ["action": ["type": "string", "enum": ["open", "read", "click", "fill", "screenshot"]], "url": string("HTTP(S) address for open"), "selector": string("Selector returned by read"), "text": string("Non-sensitive text for fill")], ["action"]),
            tool("desktop", "Use scoped macOS Accessibility control. list_apps; observe a bundleId; then press/setValue only an observed elementId. No global mouse/keyboard or activation. Writes wait for human idle; may fail if busy or permission absent.", ["action": ["type": "string", "enum": ["list_apps", "observe", "press", "setValue"]], "bundleId": string("Explicit target app bundle ID"), "elementId": string("Element ID from most recent observation"), "value": string("Non-sensitive value")], ["action"]),
            tool("complete_task", "Submit actual task outputs and verification evidence. App checks that declared files exist inside the project and writes a receipt. Be honest about limitations.", ["summary": string("Concrete completion summary"), "artifacts": array("Existing project-relative file paths, [] for chat-only tasks"), "verification": array("Specific checks actually performed and their outcomes")], ["summary", "artifacts", "verification"])
        ]
    }
}
