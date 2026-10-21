import SwiftUI

/// Configures this application's own local backend and provider credentials.
struct ConnectionSetupView: View {
    @ObservedObject var model: AppModel
    var embedded = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case address, model, key }

    private var fieldsValid: Bool {
        guard let url = URL(string: model.providerDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              !model.providerDraft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return model.hasCredentials || !model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var controlsBusy: Bool { model.isBusy || model.isTestingConnection }

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("连接模型").font(.system(size: 23, weight: .semibold))
                    Text("选择服务商，使用你自己的 API Key。无需注册 MyAgent 或登录 ChatGPT。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if !embedded {
                    Button { model.showConnectionSetup = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭连接配置")
                }
            }
            Picker("服务商", selection: $model.providerDraft.kind) {
                Text("DeepSeek").tag("deepseek")
                Text("OpenAI").tag("openai")
                Text("自定义").tag("custom")
            }.pickerStyle(.segmented).labelsHidden().disabled(controlsBusy)
                .onChange(of: model.providerDraft.kind) { _, kind in
                    switch kind {
                    case "deepseek": model.providerDraft.baseURL = "https://api.deepseek.com"; model.providerDraft.model = "deepseek-chat"
                    case "openai": model.providerDraft.baseURL = "https://api.openai.com/v1"; model.providerDraft.model = "gpt-4.1"
                    default: model.providerDraft.baseURL = ""; model.providerDraft.model = ""
                    }
                    model.apiKeyDraft = ""
                    focusedField = kind == "custom" ? .address : .key
                }
            VStack(alignment: .leading, spacing: 17) {
                field("API 地址", detail: "OpenAI-compatible API 基础地址，通常包含 /v1（以服务商要求为准）。") {
                    TextField("https://api.example.com/v1", text: $model.providerDraft.baseURL)
                        .focused($focusedField, equals: .address)
                }
                field("模型名称", detail: "填写服务商实际支持的模型 ID。") {
                    HStack {
                        TextField("模型 ID", text: $model.providerDraft.model).focused($focusedField, equals: .model)
                        if !model.models.isEmpty {
                            Menu("可用模型") {
                                ForEach(model.models) { option in
                                    Button(option.displayName) { model.providerDraft.model = option.id }
                                }
                            }.fixedSize()
                        }
                    }
                }
                field("API Key", detail: model.hasCredentials
                      ? "同一服务地址的已存密钥可留空保留；切换服务时请填写对应密钥。"
                      : "密钥保存在 macOS 钥匙串，不写入项目或聊天记录。") {
                    SecureField(model.hasCredentials ? "已保存的密钥 · 留空保留" : "粘贴 API Key", text: $model.apiKeyDraft)
                        .focused($focusedField, equals: .key)
                }
            }.disabled(controlsBusy)
            if model.isBusy {
                Label("有任务正在执行，停止任务后可更改连接。", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if model.isTestingConnection { ProgressView().controlSize(.small) }
                    Text(model.connectionTestStatus.isEmpty ? "测试连接会检查服务地址与鉴权是否可用。" : model.connectionTestStatus)
                        .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = model.lastError {
                    HStack(alignment: .top) {
                        Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                        Button(action: model.clearError) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                }
            }.padding(13).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                if !embedded {
                    Button("稍后配置") { model.showConnectionSetup = false }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("测试连接", action: model.testConnection).disabled(!fieldsValid || controlsBusy)
                Button("保存并使用", action: model.saveConnection)
                    .buttonStyle(.borderedProminent).disabled(!fieldsValid || controlsBusy)
            }
        }.font(.system(size: 14)).padding(embedded ? 20 : 28).frame(width: embedded ? nil : 610)
            .onChange(of: model.providerDraft) { old, new in
                if !model.isTestingConnection { model.connectionTestStatus = "配置已更改，请重新测试连接。" }
                if old.kind != new.kind || old.baseURL != new.baseURL { model.models = [] }
            }
    }

    private func field<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content().textFieldStyle(.roundedBorder).controlSize(.large)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
