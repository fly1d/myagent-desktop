import SwiftUI

/// Configures this application's own local backend and provider credentials.
struct ConnectionSetupView: View {
    @ObservedObject var model: AppModel
    var embedded = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case address, model, key }

    private var controlsBusy: Bool { model.isBusy || model.isTestingConnection || model.isConnecting }
    private var testFailed: Bool { model.connectionTestStatus.contains("失败") }
    private var modelIsEmpty: Bool { model.providerDraft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var invalidNoKeyMode: Bool { model.providerDraft.authMode == .none && !model.providerDraft.allowsNoKey }
    private var canTest: Bool { model.canTestConnection && !invalidNoKeyMode }
    private var canSave: Bool { canTest && !modelIsEmpty }
    private var endpointValidationError: String? {
        guard !model.providerDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !invalidNoKeyMode else { return nil }
        do {
            _ = try model.providerDraft.endpoint()
            return nil
        } catch { return error.localizedDescription }
    }
    private var hasMatchingStoredKey: Bool {
        model.canRetainDraftKey && model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var addressBinding: Binding<String> {
        Binding(get: { model.providerDraft.baseURL }, set: { address in
            guard address != model.providerDraft.baseURL else { return }
            let changed = normalizedAddress(address) != normalizedAddress(model.providerDraft.baseURL)
            model.providerDraft.baseURL = address
            if changed {
                // An entered key and model must not follow an address edit.
                model.apiKeyDraft = ""
                model.providerDraft.model = ""
                model.models = []
            }
            model.connectionTestStatus = "地址已更改，请重新测试并获取模型。"
        })
    }
    private var modelBinding: Binding<String> {
        Binding(get: { model.providerDraft.model }, set: { name in
            guard name != model.providerDraft.model else { return }
            model.providerDraft.model = name
            model.connectionTestStatus = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "模型名称已清空，可测试获取模型后再选择。" : "模型已更改，保存时会验证所选模型。"
        })
    }
    private var keyBinding: Binding<String> {
        Binding(get: { model.apiKeyDraft }, set: { key in
            guard key != model.apiKeyDraft else { return }
            model.apiKeyDraft = key
            model.models = []
            model.connectionTestStatus = "密钥已更改，请重新测试并获取模型。"
        })
    }
    private var providerSelection: Binding<String> {
        Binding(get: { model.providerDraft.kind }, set: selectProvider)
    }
    private var authenticationSelection: Binding<ProviderAuthentication> {
        Binding(get: { model.providerDraft.authMode }, set: { mode in
            guard mode != model.providerDraft.authMode else { return }
            model.providerDraft.authentication = mode
            model.apiKeyDraft = ""
            model.models = []
            model.connectionTestStatus = "鉴权方式已更改，请重新测试并获取模型。"
        })
    }
    private var modelHint: String {
        if model.models.isEmpty {
            if model.providerDraft.kind == "local" {
                return "可先留空，点击“测试并获取模型”。若列表为空，请先在本机服务中准备可用模型，再重新获取。"
            }
            return "可先留空，点击“测试并获取模型”。若服务返回空列表，请先在该服务中准备模型，或填写其支持的准确 ID。"
        }
        if model.models.count > 1 && modelIsEmpty {
            return "已获取 \(model.models.count) 个模型，请从“选择模型”选定一个后保存。"
        }
        return "已获取 \(model.models.count) 个模型。保存前需要选定模型，可从服务返回的列表中选择。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("连接模型").font(.system(size: 23, weight: .semibold))
                    Text("连接远程模型服务，或已经启动的本机兼容服务。")
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
                Button("测试并获取模型", action: model.testConnection)
                    .disabled(!canTest || controlsBusy)
                Button("保存并使用", action: model.saveConnection)
                    .buttonStyle(.borderedProminent).disabled(!canSave || controlsBusy)
                    .help(modelIsEmpty ? "请先获取并选择模型，或填写准确的模型 ID" : "保存此服务与选定的模型")
            }
        }.font(.system(size: 14)).padding(embedded ? 20 : 28).frame(width: embedded ? nil : 610)
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
            Picker("服务商", selection: providerSelection) {
                Text("DeepSeek").tag("deepseek")
                Text("OpenAI").tag("openai")
                Text("本机").tag("local")
                Text("自定义").tag("custom")
            }.pickerStyle(.segmented).labelsHidden().disabled(controlsBusy)
            if model.providerDraft.kind == "local" {
                Text("连接你已经启动的 OpenAI-compatible 本机服务，并获取其中可用的模型。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 17) {
                field("API 地址", detail: "兼容服务的 API 基础地址，通常包含 /v1（以服务要求为准）。", validation: endpointValidationError) {
                    TextField(model.providerDraft.kind == "local" ? "http://127.0.0.1:11434/v1" : "https://api.example.com/v1", text: addressBinding)
                        .focused($focusedField, equals: .address)
                }
                authenticationControls
                field("模型名称", detail: modelHint) {
                    HStack {
                        TextField("先获取模型，或填写模型 ID", text: modelBinding).focused($focusedField, equals: .model)
                        if !model.models.isEmpty {
                            Menu(modelIsEmpty ? "选择模型" : "可用模型") {
                                ForEach(model.models) { option in
                                    Button(option.displayName) { modelBinding.wrappedValue = option.id }
                                }
                            }.fixedSize()
                        }
                    }
                }
                if model.providerDraft.requiresAPIKey {
                    field("API Key", detail: hasMatchingStoredKey
                          ? "当前服务地址已有钥匙串密钥，留空可继续使用；输入新值可替换。"
                          : "填写当前服务地址对应的 API Key。密钥保存到 macOS 钥匙串，不写入项目或聊天。") {
                        SecureField(hasMatchingStoredKey ? "当前地址已有密钥 · 留空保留" : "粘贴当前服务的 API Key", text: keyBinding)
                            .focused($focusedField, equals: .key)
                    }
                }
            }.disabled(controlsBusy)
            if model.isBusy {
                Label("有任务正在执行，停止任务后可更改连接。", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            connectionResult
        }
    }

    @ViewBuilder
    private var authenticationControls: some View {
        if model.providerDraft.allowsNoKey {
            VStack(alignment: .leading, spacing: 8) {
                Text("鉴权方式").font(.system(size: 12, weight: .semibold))
                Picker("鉴权方式", selection: authenticationSelection) {
                    Text("API Key").tag(ProviderAuthentication.apiKey)
                    Text("无密钥（仅本机）").tag(ProviderAuthentication.none)
                }.pickerStyle(.segmented).labelsHidden()
                if model.providerDraft.authMode == .none {
                    Text("已明确选择无密钥模式，不读取或发送钥匙串中的 API Key。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        } else if invalidNoKeyMode {
            VStack(alignment: .leading, spacing: 9) {
                Label("当前地址不能使用无密钥模式", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                Text("无密钥仅允许本机 loopback 地址。请恢复本机地址，或明确改用 API Key 后再测试和保存。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("改用 API Key") { authenticationSelection.wrappedValue = .apiKey }
                    .controlSize(.small)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        } else if model.providerDraft.kind == "local" || model.providerDraft.kind == "custom" {
            Text("此地址需要 API Key。无密钥模式仅用于本机 loopback 服务。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var connectionResult: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                if model.isTestingConnection { ProgressView().controlSize(.small) }
                else if testFailed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                Text(model.connectionTestStatus.isEmpty ? "可先测试并获取模型，模型名称暂时留空也可以。" : model.connectionTestStatus)
                    .font(.system(size: 12)).foregroundStyle(testFailed ? Color.orange : Color.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if testFailed {
                Text(model.isConnected ? "核对服务是否已启动、地址和鉴权方式，然后重新测试。" : "请先重试本地后端连接，再重新测试模型服务。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !model.models.isEmpty && modelIsEmpty {
                Text("连接已返回模型列表。请选择模型后保存。")
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

    private func selectProvider(_ kind: String) {
        guard kind != model.providerDraft.kind else { return }
        model.providerDraft.kind = kind
        switch kind {
        case "local":
            model.providerDraft.baseURL = "http://127.0.0.1:11434/v1"
            model.providerDraft.model = ""
            model.providerDraft.authentication = ProviderAuthentication.none
        case "deepseek":
            model.providerDraft.baseURL = "https://api.deepseek.com"
            model.providerDraft.model = "deepseek-chat"
            model.providerDraft.authentication = ProviderAuthentication.apiKey
        case "openai":
            model.providerDraft.baseURL = "https://api.openai.com/v1"
            model.providerDraft.model = "gpt-4.1"
            model.providerDraft.authentication = ProviderAuthentication.apiKey
        default:
            model.providerDraft.baseURL = ""
            model.providerDraft.model = ""
            model.providerDraft.authentication = ProviderAuthentication.apiKey
        }
        model.apiKeyDraft = ""
        model.models = []
        model.connectionTestStatus = "配置已更改，请测试并获取模型。"
        focusedField = kind == "local" ? nil : kind == "custom" ? .address : .key
    }

    private func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func retryBackend() {
        model.clearError()
        Task { await model.reconnect() }
    }

    private func field<Content: View>(_ title: String, detail: String, validation: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content().textFieldStyle(.roundedBorder).controlSize(.large)
            if let validation {
                Text(validation).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
