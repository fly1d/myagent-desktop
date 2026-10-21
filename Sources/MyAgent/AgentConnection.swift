import Foundation

/// Owns one app-server process. All application state stays on the main actor;
/// pipe reads and serialized writes run outside the UI thread.
@MainActor
final class AgentConnection {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onServerRequest: ((Any, String, [String: Any]) -> Void)?
    var onClosed: ((String) -> Void)?

    private struct PendingCall {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>
    }

    private enum ConnectionError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): return message }
        }
    }

    private static let maximumFrameBytes = 8 * 1_024 * 1_024
    private static let requestTimeout: UInt64 = 60_000_000_000
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var writer = DispatchQueue(label: "myagent.app-server.stdin")
    private var generation: UUID?
    private var nextID: UInt64 = 0
    private var pending: [String: PendingCall] = [:]
    private var receiveBuffer = Data()
    private var diagnosticByteCount = 0

    func launch(binary: URL, home: URL) async throws {
        stop()
        guard binary.isFileURL, FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ConnectionError.message("应用内的 Agent 运行时不存在或无法执行。")
        }
        guard home.isFileURL else {
            throw ConnectionError.message("Agent 数据目录必须是本地目录。")
        }
        let ownHome = home.standardizedFileURL.resolvingSymlinksInPath()
        let existingCodexHome = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex").standardizedFileURL.resolvingSymlinksInPath()
        guard ownHome != existingCodexHome else {
            throw ConnectionError.message("独立应用不能使用现有 Codex 的数据目录。")
        }
        try FileManager.default.createDirectory(
            at: ownHome, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.executableURL = binary
        child.arguments = ["--stdio"]
        child.currentDirectoryURL = ownHome
        // A small OS-only allowlist prevents inherited provider credentials,
        // CODEX overrides, and the parent app's private runtime environment
        // from selecting an account or changing this independent runtime.
        let inherited = ProcessInfo.processInfo.environment
        let allowedKeys = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "__CF_USER_TEXT_ENCODING"]
        var environment: [String: String] = [:]
        for key in allowedKeys { environment[key] = inherited[key] }
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "dumb"
        environment["CODEX_HOME"] = ownHome.path
        environment["MYAGENT_HOME"] = ownHome.path
        child.environment = environment
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe

        let token = UUID()
        generation = token
        process = child
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        diagnostics = stderrPipe.fileHandleForReading
        receiveBuffer.removeAll(keepingCapacity: false)
        diagnosticByteCount = 0
        writer = DispatchQueue(label: "myagent.app-server.stdin.\(token.uuidString)")
        child.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.finish("Agent 运行时已退出（\(status)）。", notify: true)
            }
        }
        do {
            try child.run()
        } catch {
            finish("无法启动 Agent 运行时。", notify: false)
            throw ConnectionError.message("无法启动 Agent 运行时：\(error.localizedDescription)")
        }

        let stdoutStream = Self.chunks(from: stdoutPipe.fileHandleForReading, failOnOverflow: true)
        outputTask = Task { @MainActor [weak self] in
            do {
                for try await bytes in stdoutStream {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    try self.receive(bytes)
                }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.finish("Agent 运行时连接已关闭。", notify: true)
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.finish(error.localizedDescription, notify: true)
            }
        }
        let stderrStream = Self.chunks(from: stderrPipe.fileHandleForReading, failOnOverflow: false)
        diagnosticTask = Task { @MainActor [weak self] in
            do {
                for try await bytes in stderrStream {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    // stderr can contain credentials or full prompts. Drain it
                    // without retaining or displaying any of its raw contents.
                    self.diagnosticByteCount = min(1_000_000_000, self.diagnosticByteCount + bytes.count)
                }
            } catch { /* Diagnostics never become protocol or UI content. */ }
        }
        do {
            _ = try await call("initialize", params: [
                "clientInfo": ["name": "myagent_desktop", "title": "MyAgent", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true]
            ])
            guard generation == token else { throw CancellationError() }
            try send(["method": "initialized"])
        } catch {
            if generation == token { finish("Agent 运行时初始化失败。", notify: false) }
            throw error
        }
    }

    func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard generation != nil, process?.isRunning == true else {
            throw ConnectionError.message("Agent 运行时尚未连接。")
        }
        nextID &+= 1
        let id = "myagent-\(nextID)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: Self.requestTimeout) }
                    catch { return }
                    self?.reject(id, error: ConnectionError.message("Agent 请求超时（60 秒）：\(method)"))
                }
                pending[id] = PendingCall(continuation: continuation, timeout: timeout)
                do {
                    try send(["id": id, "method": method, "params": params])
                } catch {
                    reject(id, error: error)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.reject(id, error: CancellationError()) }
        }
    }

    func respond(id: Any, result: [String: Any]) {
        do { try send(["id": id, "result": result]) }
        catch { finish("无法发送工具执行结果。", notify: true) }
    }

    func respondError(id: Any, message: String) {
        do { try send(["id": id, "error": ["code": -32603, "message": message]]) }
        catch { finish("无法发送工具错误信息。", notify: true) }
    }

    func stop() {
        finish("Agent 运行时已停止。", notify: false)
    }

    private func send(_ message: [String: Any]) throws {
        guard let input, let token = generation else {
            throw ConnectionError.message("Agent 运行时连接已关闭。")
        }
        guard JSONSerialization.isValidJSONObject(message) else {
            throw ConnectionError.message("Agent 请求不是有效的 JSON。")
        }
        var bytes = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard bytes.count <= Self.maximumFrameBytes else {
            throw ConnectionError.message("Agent 请求超过 8 MB 限制。")
        }
        bytes.append(0x0A)
        let frame = bytes
        writer.async { [weak self] in
            do { try input.write(contentsOf: frame) }
            catch {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.finish("无法写入 Agent 运行时连接。", notify: true)
                }
            }
        }
    }

    private func receive(_ bytes: Data) throws {
        receiveBuffer.append(bytes)
        // A chunk can contain several frames; enforce the bound on each
        // individual frame rather than on their combined transport chunk.
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let count = receiveBuffer.distance(from: receiveBuffer.startIndex, to: newline)
            guard count <= Self.maximumFrameBytes else {
                throw ConnectionError.message("Agent 响应超过 8 MB 限制。")
            }
            let frame = Data(receiveBuffer[..<newline])
            receiveBuffer.removeSubrange(...newline)
            if frame.isEmpty { continue }
            guard let message = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                throw ConnectionError.message("Agent 运行时返回了无效的协议消息。")
            }
            route(message)
        }
        guard receiveBuffer.count <= Self.maximumFrameBytes else {
            throw ConnectionError.message("Agent 响应超过 8 MB 限制。")
        }
    }

    private func route(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"], !(id is NSNull) {
                if let onServerRequest { onServerRequest(id, method, params) }
                else { respondError(id: id, message: "Client does not handle this server request.") }
            } else {
                onEvent?(method, params)
            }
            return
        }
        guard let id = message["id"] as? String, let call = pending.removeValue(forKey: id) else { return }
        call.timeout.cancel()
        if let error = message["error"] as? [String: Any] {
            let description = error["message"] as? String ?? "Agent 请求失败。"
            call.continuation.resume(throwing: ConnectionError.message(description))
        } else if let result = message["result"] as? [String: Any] {
            call.continuation.resume(returning: result)
        } else if message["result"] is NSNull {
            call.continuation.resume(returning: [:])
        } else {
            call.continuation.resume(throwing: ConnectionError.message("Agent 请求缺少有效响应。"))
        }
    }

    private func reject(_ id: String, error: Error) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timeout.cancel()
        call.continuation.resume(throwing: error)
    }

    private func finish(_ reason: String, notify: Bool) {
        let wasConnected = generation != nil
        generation = nil
        let child = process
        process = nil
        child?.terminationHandler = nil
        output?.readabilityHandler = nil
        diagnostics?.readabilityHandler = nil
        outputTask?.cancel()
        diagnosticTask?.cancel()
        outputTask = nil
        diagnosticTask = nil
        try? input?.close()
        try? output?.close()
        try? diagnostics?.close()
        input = nil
        output = nil
        diagnostics = nil
        if child?.isRunning == true { child?.terminate() }
        receiveBuffer.removeAll(keepingCapacity: false)
        let waiting = pending
        pending.removeAll()
        for call in waiting.values {
            call.timeout.cancel()
            call.continuation.resume(throwing: ConnectionError.message(reason))
        }
        if notify && wasConnected { onClosed?(reason) }
    }

    private static func chunks(from handle: FileHandle, failOnOverflow: Bool) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(failOnOverflow ? 128 : 8)) { continuation in
            handle.readabilityHandler = { source in
                // read(upToCount:) can wait to fill its requested length on a
                // pipe. availableData consumes the bytes currently readable,
                // allowing a small JSON-RPC response to complete immediately.
                let bytes = source.availableData
                guard !bytes.isEmpty else {
                    source.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                if case .dropped = continuation.yield(bytes), failOnOverflow {
                    source.readabilityHandler = nil
                    continuation.finish(throwing: ConnectionError.message("Agent 输出积压超限，连接已停止。"))
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }
}
