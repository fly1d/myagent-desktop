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
    private var controlsBusy: Bool { model.isBusy || model.isTestingConnection || model.isConnecting }
    private var testFailed: Bool { model.connectionTestStatus.contains("失败") }

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("连接模型").font(.system(size: 23, weight: .semibold))
                    Text("选择服务商，使用你自己的 API Key。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if !embedded {
                    Button { model.showConnectionSetup = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭连接配置")
                }
            }
            if embedded {
                configurationForm
            } else {
                ScrollView { configurationForm.padding(.trailing, 3) }.frame(maxHeight: 410)
            }
            HStack(spacing: 10) {
                if !embedded {
                    Button("稍后配置") { model.showConnectionSetup = false }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(testFailed ? "重试测试" : "测试连接", action: model.testConnection)
                    .disabled(!fieldsValid || controlsBusy)
                Button("保存并使用", action: model.saveConnection)
                    .buttonStyle(.borderedProminent).disabled(!fieldsValid || controlsBusy)
            }
        }.font(.system(size: 14)).padding(embedded ? 20 : 28).frame(width: embedded ? nil : 610)
            .onChange(of: model.providerDraft) { old, new in
                if !model.isTestingConnection { model.connectionTestStatus = "配置已更改，请重新测试连接。" }
                if old.kind != new.kind || old.baseURL != new.baseURL { model.models = [] }
            }
            .onChange(of: model.apiKeyDraft) { _, _ in
                if !model.isTestingConnection {
                    model.connectionTestStatus = "密钥已更改，请重新测试连接。"
                    model.models = []
                }
            }
    }

    private var configurationForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.isConnected {
                HStack(alignment: .top, spacing: 10) {
                    if model.isConnecting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "network").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.isConnecting ? "正在启动本地后端" : "本地后端未连接")
                            .font(.system(size: 13, weight: .medium))
                        Text(model.connectionLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                        if !model.isConnecting {
                            Text("先恢复本地后端，再验证模型服务；重连不会自动发送草稿。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试后端", action: retryBackend)
                        .controlSize(.small).disabled(controlsBusy)
                }.padding(13).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
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
                HStack(alignment: .top, spacing: 8) {
                    if model.isTestingConnection { ProgressView().controlSize(.small) }
                    else if testFailed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Text(model.connectionTestStatus.isEmpty ? "测试连接会检查服务地址与鉴权是否可用。" : model.connectionTestStatus)
                        .font(.system(size: 12)).foregroundStyle(testFailed ? Color.orange : Color.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if testFailed {
                    Text(model.isConnected ? "可以修改地址、模型或密钥后重试；当前草稿不会自动发送。" : "请先重试本地后端连接，再重新测试模型服务。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
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
        }
    }

    private func retryBackend() {
        model.clearError()
        Task { await model.reconnect() }
    }

    private func field<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content().textFieldStyle(.roundedBorder).controlSize(.large)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
