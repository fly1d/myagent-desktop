import Foundation
import Darwin

enum RunPhase: String, Codable {
    case idle, connecting, running, waiting, needsReview, paused, completed, failed
    var label: String {
        switch self {
        case .idle: return "准备就绪"
        case .connecting: return "正在连接"
        case .running: return "正在执行"
        case .waiting: return "等待你的选择"
        case .needsReview: return "验收待确认"
        case .paused: return "已停止"
        case .completed: return "本轮完成"
        case .failed: return "需要处理"
        }
    }
}

struct ChatEntry: Identifiable, Codable {
    var id = UUID()
    var role: String
    var text: String
    var createdAt = Date()
}

struct AgentTask: Identifiable, Codable {
    var id = UUID()
    var engineID: String?
    var title: String
    var workspace: String
    var messages: [ChatEntry] = []
    var phase: RunPhase = .idle
    var createdAt = Date()
    var updatedAt = Date()
    var automaticRounds = 0
    var draft: String? = nil
    // Kept until the backend acknowledges this exact input. The turn ID lets
    // recovery distinguish an unsubmitted prompt from a lost RPC reply.
    var pendingInput: String? = nil
    var pendingTurnID: String? = nil
}

struct ArtifactItem: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var bytes: Int
    var kind: String
}

struct ActivityEntry: Identifiable {
    var id = UUID()
    var at = Date()
    var title: String
    var detail: String
    var kind: String = "info"
}

struct ChoiceCard: Identifiable, Codable {
    var id: String
    var title: String
    var description: String
    var deliverables: [String]
    var previewPaths: [String]
    var impact: String
    var nextStep: String
}

struct PendingChoice: Identifiable {
    var id = UUID()
    var title: String
    var options: [ChoiceCard]
}

struct PendingQuestion: Identifiable {
    var id = UUID()
    var question: String
    var context: String = ""
    var options: [String] = []
    var placeholder: String = "输入你的回答…"
}

struct PendingPermission: Identifiable {
    var id = UUID()
    var title: String
    var detail: String
    var scope: String
    var kind: String
    var expiresAt = Date().addingTimeInterval(90)
}

struct ModelOption: Identifiable {
    var id: String
    var displayName: String
    var isDefault: Bool
}

struct AppSettings: Codable {
    var model: String?
    var quietMode = true
    var proactive = true
    var maxAutomaticRounds = 2
}

enum ProviderAuthentication: String, Codable {
    case apiKey, none
}

struct ProviderDraft: Codable, Equatable {
    var kind = "deepseek"
    var baseURL = "https://api.deepseek.com"
    var model = "deepseek-chat"
    // Optional for snapshots written before explicit authentication modes.
    var authentication: ProviderAuthentication? = nil

    var authMode: ProviderAuthentication { authentication ?? .apiKey }
    var requiresAPIKey: Bool { authMode == .apiKey }
    var allowsNoKey: Bool {
        ["custom", "local"].contains(kind) && (try? endpoint()).map(Self.isLoopback) == true
    }

    func endpoint() throws -> URL {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !text.components(separatedBy: "://").dropFirst().joined(separator: "://").prefix(while: { $0 != "/" }).contains("@") else {
            throw AppFailure.message("请填写有效的 API 根地址，不含账号、密码、查询参数或片段。")
        }
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && Self.isLoopback(url)) else {
            throw AppFailure.message("远端模型服务需要 HTTPS；HTTP 仅可用于本机地址。")
        }
        return url
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host == "localhost" { return true }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return withUnsafeBytes(of: ipv4) { $0.first == 127 }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: ipv6) { bytes in bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1 }
        }
        return false
    }
}

struct PersistedAppState: Codable {
    var version = 1
    var selectedTaskID: UUID?
    var tasks: [AgentTask]
    var settings: AppSettings
    var provider: ProviderDraft? = nil
    var unassignedDraft: String? = nil
    var revision: Int64? = nil
    var connectionEnabled: Bool? = nil
}

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

enum WorkspacePaths {
    static func confinedFile(_ path: String, workspace: String) throws -> URL {
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath()
        let input = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let file = input.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { throw AppFailure.message("文件必须在当前项目目录内。") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw AppFailure.message("预览文件必须是已存在的普通文件。") }
        return file
    }
}
