import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        TabView {
            connectionSettings.tabItem { Label("模型连接", systemImage: "network") }
            behaviorSettings.tabItem { Label("执行与权限", systemImage: "slider.horizontal.3") }
            appearanceSettings.tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
        }.padding(15).font(.system(size: 14))
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }

    private var connectionSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ConnectionSetupView(model: model, embedded: true)
                Divider().padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 13) {
                    Text("本地后端").font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 8) {
                        if model.isConnecting { ProgressView().controlSize(.small) }
                        Text(model.connectionLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(model.isConnecting ? "正在启动…" : "重新连接后端") {
                            model.clearError()
                            Task { await model.reconnect() }
                        }.disabled(model.isBusy || model.isTestingConnection || model.isConnecting)
                        Spacer()
                        if model.hasCredentials {
                            Button("断开模型连接", action: model.disconnectProvider)
                                .disabled(model.isBusy || model.isTestingConnection || model.isConnecting)
                        }
                    }
                }.padding(20)
            }
        }
    }

    private var behaviorSettings: some View {
        Form {
            Section {
                Toggle("主动检查并继续推进任务", isOn: $model.settings.proactive)
                    .onChange(of: model.settings.proactive) { _, _ in model.saveSettings() }
                Stepper(value: $model.settings.maxAutomaticRounds, in: 0...3) {
                    LabeledContent("每轮最多自动跟进", value: "\(model.settings.maxAutomaticRounds) 次")
                }.onChange(of: model.settings.maxAutomaticRounds) { _, _ in model.saveSettings() }
                Text("主动跟进有次数上限。需要决策或权限时等待答复；验收未完成时可在任务中继续核验。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } header: { Text("任务推进") }
            Section("办公体验") {
                Toggle("安静模式", isOn: $model.settings.quietMode)
                    .onChange(of: model.settings.quietMode) { _, _ in model.saveSettings() }
                Text("控制请求只在应用内显示。安静模式不播放提示音；关闭后播放轻提示音，两种模式都不切换前台。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("桌面协助") {
                LabeledContent("状态") {
                    Text(model.desktopStatus).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                Button("请求 macOS 辅助功能权限…", action: model.enableAccessibility)
                Text("使用有限 AX 定向动作，不自动激活应用、不注入全局键鼠。每次控制需单独授权；写入等待空闲 3 秒，20 秒仍忙则暂停。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let scope = model.activeControlScope {
                    Text(scope).font(.system(size: 12)).foregroundStyle(.orange)
                    Button("停止当前执行", action: model.stop)
                }
            }
        }.formStyle(.grouped)
    }

    private var appearanceSettings: some View {
        Form {
            Section("主题") {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }.pickerStyle(.segmented)
            }
        }.formStyle(.grouped)
    }
}
