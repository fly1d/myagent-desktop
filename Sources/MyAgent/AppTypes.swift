import Foundation

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

struct ProviderDraft: Codable, Equatable {
    var kind = "deepseek"
    var baseURL = "https://api.deepseek.com"
    var model = "deepseek-chat"
}

struct PersistedAppState: Codable {
    var version = 1
    var selectedTaskID: UUID?
    var tasks: [AgentTask]
    var settings: AppSettings
    var provider: ProviderDraft? = nil
    var unassignedDraft: String? = nil
    var revision: Int64? = nil
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
