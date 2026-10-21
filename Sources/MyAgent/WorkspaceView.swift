import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var inspectorVisible = false
    @State private var search = ""
    @State private var inputHeight: CGFloat = 60
    @State private var followsLatest = true
    @State private var userIsScrolling = false
    @State private var activeSheet: WorkspaceSheet?

    private var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }
    private var needsReview: Bool { model.currentTask?.phase.rawValue == "needsReview" }
    private var selectedIsRunning: Bool {
        guard model.isBusy, let phase = model.currentTask?.phase else { return false }
        return [.connecting, .running, .waiting].contains(phase)
    }
    private var projectName: String { URL(fileURLWithPath: model.workspacePath).lastPathComponent }
    private var connectionActionTitle: String {
        if model.isConnecting { return "正在启动…" }
        if !model.isConnected { return "重连后端" }
        if model.isTestingConnection { return "正在验证…" }
        return model.hasCredentials ? "发送" : "配置模型"
    }
    private var connectionSummary: String {
        if model.isConnecting { return "正在启动本地后端" }
        if !model.isConnected { return "本地后端已断开" }
        if model.isTestingConnection { return "正在验证模型连接" }
        return model.hasCredentials ? "模型已配置" : "待配置模型"
    }
    private var visibleTasks: [AgentTask] {
        model.tasks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
            VStack(spacing: 0) {
                header
                if !model.canRun { connectionNotice }
                if let error = model.lastError { errorNotice(error) }
                if needsReview { reviewNotice }
                conversation
                composer
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            if inspectorVisible { inspector.frame(minWidth: 260, idealWidth: 300, maxWidth: 400) }
        }
        .font(.system(size: 14))
        .preferredColorScheme(colorScheme)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showConnectionSetup = true } label: {
                    Label(model.hasCredentials ? "模型连接" : "配置模型", systemImage: model.canRun ? "checkmark.circle" : "network")
                }.help("配置模型 API 与密钥")
                SettingsLink { Image(systemName: "gearshape") }.help("设置")
                Button { inspectorVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help("项目文件与执行详情")
            }
        }
        .sheet(item: sheetBinding, onDismiss: { DispatchQueue.main.async { synchronizeSheet() } }) { sheet in
            Group {
                switch sheet {
                case .connection: ConnectionSetupView(model: model)
                case .permission(let id):
                    if let request = model.pendingPermission, request.id == id { PermissionSheet(model: model, request: request) }
                case .choice(let id):
                    if let choice = model.pendingChoice, choice.id == id { ChoiceSheet(model: model, choice: choice) }
                case .preview: FilePreviewSheet(model: model)
                }
            }.preferredColorScheme(colorScheme)
        }
        .onAppear { synchronizeSheet() }
        .onChange(of: model.showConnectionSetup) { _, _ in synchronizeSheet() }
        .onChange(of: model.pendingPermission?.id) { _, _ in synchronizeSheet() }
        .onChange(of: model.pendingChoice?.id) { _, _ in synchronizeSheet() }
        .onChange(of: model.showPreview) { _, _ in synchronizeSheet() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MyAgent").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: model.newTask) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("新建任务（⌘N）")
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 17)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索任务", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 12)).padding(8)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 12).padding(.bottom, 12)
            List(selection: Binding<UUID?>(get: { model.selectedTaskID }, set: { if let id = $0 { model.selectTask(id) } })) {
                Section("任务") {
                    ForEach(visibleTasks) { task in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: phaseSymbol(task.phase)).font(.system(size: 12))
                                .frame(width: 16).padding(.top, 2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text(task.phase.label).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 5).tag(task.id)
                    }
                    if visibleTasks.isEmpty {
                        Text(search.isEmpty ? "还没有任务" : "没有匹配的任务")
                            .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.vertical, 5)
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Divider().padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("当前项目").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: model.chooseWorkspace) { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.plain).help("选择项目目录（⌘O）")
                }
                Button(action: model.openProjectFolder) {
                    Label(projectName, systemImage: "folder").font(.system(size: 12)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help(model.workspacePath)
                HStack(spacing: 6) {
                    Circle().fill(model.canRun ? Color.green : Color.secondary).frame(width: 5, height: 5)
                    Text(connectionSummary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(17)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.currentTask?.title ?? "新任务").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(!model.isConnected ? connectionSummary : model.currentTask?.phase.label ?? (model.canRun ? "准备开始" : "先配置一个模型连接"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if model.isBusy {
                Button(action: model.stop) {
                    Label(selectedIsRunning ? "停止" : "停止后台任务", systemImage: "stop.fill")
                }.controlSize(.small).help("停止正在执行的任务（⌘.）")
            }
        }.padding(.horizontal, 24).padding(.vertical, 14)
            .overlay(alignment: .bottom) { Divider() }
    }

    private var connectionNotice: some View {
        HStack(alignment: .center, spacing: 12) {
            if model.isConnecting || model.isTestingConnection {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "network").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(!model.isConnected || model.isTestingConnection ? connectionSummary : "连接你自己的模型")
                    .font(.system(size: 13, weight: .medium))
                Text(!model.isConnected ? "\(model.connectionLabel)。先恢复本地后端，再检查模型服务。" : model.isTestingConnection ? model.connectionTestStatus : "填写服务地址、模型 ID 与 API Key，密钥由本机钥匙串保存。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !model.isConnected {
                Button(model.isConnecting ? "正在启动…" : "重试后端", action: retryBackend)
                    .controlSize(.small).disabled(model.isConnecting || model.isTestingConnection)
            } else {
                Button(model.isTestingConnection ? "查看连接" : "配置模型") { model.showConnectionSetup = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }.padding(.horizontal, 24).padding(.vertical, 12).background(Color.accentColor.opacity(0.045))
    }

    private var reviewNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("执行已结束，交付物还需要核验").font(.system(size: 13, weight: .medium))
                Text("可以先查看文件，再让 Agent 继续检查结果。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("继续核验", action: model.continueReview).disabled(!model.canRun || model.isBusy)
                .controlSize(.small)
        }.padding(.horizontal, 24).padding(.vertical, 12).background(Color.orange.opacity(0.06))
    }

    private func errorNotice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !model.canRun {
                if !model.isConnected {
                    Button("重试后端", action: retryBackend).controlSize(.small)
                        .disabled(model.isConnecting || model.isTestingConnection)
                } else {
                    Button("连接设置") { model.showConnectionSetup = true }.controlSize(.small)
                }
            }
            Button(action: model.clearError) { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("关闭这条提示")
        }.padding(.horizontal, 24).padding(.vertical, 11).background(Color.orange.opacity(0.06))
    }

    private var conversation: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 25) {
                        if model.currentTask?.messages.isEmpty != false {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("今天想完成什么？").font(.system(size: 23, weight: .semibold))
                                Text("描述目标。需要你判断时，会带着交付物和下一步回来。")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                            }.padding(.top, 38).padding(.bottom, 16)
                        }
                        ForEach(model.currentTask?.messages ?? []) { entry in MessageRow(entry: entry) }
                        if selectedIsRunning {
                            HStack(spacing: 9) {
                                ProgressView().controlSize(.mini)
                                Text(model.currentTask?.phase == .waiting ? "等待你的答复" : "正在处理…")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }.padding(.leading, 34)
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }.padding(26).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity)
                        .background {
                            ConversationScrollObserver(onScrollBegan: {
                                userIsScrolling = true
                                followsLatest = false
                            }, onScrollEnded: { atBottom in
                                userIsScrolling = false
                                followsLatest = atBottom
                            })
                        }
                }
                    .onChange(of: model.currentTask?.messages.last?.text) { _, _ in
                        if followsLatest && !userIsScrolling { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                    }
                    .onChange(of: model.selectedTaskID) { _, _ in
                        userIsScrolling = false
                        followsLatest = true
                        DispatchQueue.main.async { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                    }
                    .overlay(alignment: .bottom) {
                        if !followsLatest {
                            Button {
                                followsLatest = true
                                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                            } label: { Label("回到最新", systemImage: "arrow.down") }
                                .buttonStyle(.bordered).controlSize(.small).padding(.bottom, 10)
                        }
                    }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("输入目标或补充说明…").foregroundStyle(.tertiary)
                            .padding(.leading, 8).padding(.top, 8).allowsHitTesting(false)
                    }
                    GrowingPromptEditor(text: $model.draft, measuredHeight: $inputHeight, onSend: send)
                        .frame(height: inputHeight).id(model.selectedTaskID)
                }
                HStack(spacing: 10) {
                    Button(action: model.chooseWorkspace) {
                        Label(projectName, systemImage: "folder").lineLimit(1)
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).help(model.workspacePath)
                    Spacer(minLength: 4)
                    Text("⌘ Return").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Button(action: send) {
                        Label(connectionActionTitle, systemImage: model.canRun ? "arrow.up" : "network")
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(model.isBusy || model.isConnecting || model.isTestingConnection || (model.canRun && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .help("发送任务（⌘Return），Return 换行")
                }
            }.padding(11)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.13)) }
            HStack {
                Text(model.isBusy ? (selectedIsRunning ? "执行中，可以先写下下一条。" : "其他任务正在执行，可以先起草。") : model.draft.isEmpty ? "Return 换行 · ⌘Return 发送" : "当前任务草稿 · Return 换行 · ⌘Return 发送")
                Spacer()
                if model.settings.quietMode { Label("安静模式", systemImage: "bell.slash") }
            }.font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 2)
        }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 15)
            .frame(maxWidth: 888).frame(maxWidth: .infinity)
    }

    private func send() {
        guard !model.isBusy, !model.isConnecting, !model.isTestingConnection else { return }
        if !model.isConnected { retryBackend() }
        else if !model.hasCredentials { model.showConnectionSetup = true }
        else { model.sendPrompt() }
    }

    private func retryBackend() {
        model.clearError()
        Task { await model.reconnect() }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack {
                    Text("项目与执行").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button(action: model.openProjectFolder) { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.plain).help("在 Finder 中打开项目")
                }
                VStack(alignment: .leading, spacing: 9) {
                    Label("控制状态", systemImage: "hand.raised").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(model.desktopStatus).font(.system(size: 12))
                    if let scope = model.activeControlScope {
                        Text(scope).font(.system(size: 12)).foregroundStyle(.orange)
                        Button("停止当前执行", action: model.stop).controlSize(.small)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 10) {
                    inspectorTitle("项目文件", symbol: "doc.on.doc")
                    if model.artifacts.isEmpty {
                        Text("还没有可预览文件").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    ForEach(model.artifacts) { artifact in
                        Button { model.previewPath(artifact.path) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: ["png", "jpg", "jpeg", "webp"].contains(artifact.kind.lowercased()) ? "photo" : "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(artifact.name).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.bytes), countStyle: .file))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(artifact.path)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    inspectorTitle("后台浏览器", symbol: "globe")
                    if let image = model.browserImage {
                        Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("后台浏览器实际截图")
                    } else {
                        Text("尚无浏览器画面").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    Text(model.browserTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                VStack(alignment: .leading, spacing: 13) {
                    inspectorTitle("活动", symbol: "clock")
                    if model.activities.isEmpty {
                        Text("执行活动会显示在这里").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    ForEach(Array(model.activities.prefix(30))) { activity in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(activity.title).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(activity.at, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            if !activity.detail.isEmpty {
                                Text(activity.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled)
                            }
                        }
                    }
                }
            }.padding(18)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func inspectorTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func phaseSymbol(_ phase: RunPhase) -> String {
        switch phase {
        case .running, .connecting: return "circle.dotted"
        case .waiting: return "hand.raised"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .paused: return "pause.circle"
        default: return phase.rawValue == "needsReview" ? "checkmark.seal" : "bubble.left"
        }
    }

    private var sheetBinding: Binding<WorkspaceSheet?> {
        Binding(get: { activeSheet }, set: { next in
            if next == nil, let old = activeSheet {
                switch old {
                case .connection: model.showConnectionSetup = false
                case .preview: model.showPreview = false
                case .permission: if model.pendingPermission != nil { model.respondPermission(false) }
                case .choice: if model.pendingChoice != nil { model.declineChoice() }
                }
            }
            activeSheet = next
        })
    }

    private func synchronizeSheet() {
        if let sheet = activeSheet {
            let valid: Bool
            switch sheet {
            case .connection: valid = model.showConnectionSetup
            case .permission(let id): valid = model.pendingPermission?.id == id
            case .choice(let id): valid = model.pendingChoice?.id == id
            case .preview: valid = model.showPreview
            }
            if !valid { activeSheet = nil }
            return
        }
        if model.pendingPermission != nil { activeSheet = .permission(model.pendingPermission!.id) }
        else if model.pendingChoice != nil { activeSheet = .choice(model.pendingChoice!.id) }
        else if model.showConnectionSetup { activeSheet = .connection }
        else if model.showPreview { activeSheet = .preview }
    }
}

private enum WorkspaceSheet: Identifiable {
    case connection, permission(UUID), choice(UUID), preview
    var id: String {
        switch self {
        case .connection: return "connection"
        case .permission(let id): return "permission-\(id)"
        case .choice(let id): return "choice-\(id)"
        case .preview: return "preview"
        }
    }
}

/// Observes only the native scroll view containing this conversation. Content
/// growth never changes follow mode; actual user scrolling does.
private struct ConversationScrollObserver: NSViewRepresentable {
    var onScrollBegan: () -> Void
    var onScrollEnded: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ScrollMarkerView {
        let view = ScrollMarkerView()
        view.onAttach = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.attach(to: view) }
        }
        return view
    }
    func updateNSView(_ view: ScrollMarkerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: view)
    }
    static func dismantleNSView(_ view: ScrollMarkerView, coordinator: Coordinator) {
        view.onAttach = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var parent: ConversationScrollObserver
        private weak var scrollView: NSScrollView?
        private var tokens: [NSObjectProtocol] = []
        private var liveScrolling = false
        private var previousY: CGFloat = 0

        init(_ parent: ConversationScrollObserver) { self.parent = parent }
        func attach(to view: NSView) {
            guard let scroll = view.enclosingScrollView, scroll !== scrollView else { return }
            detach()
            scrollView = scroll
            previousY = scroll.documentVisibleRect.minY
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.liveScrolling = true
                    self.parent.onScrollBegan()
                }
            })
            tokens.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.liveScrolling = false
                    self.parent.onScrollEnded(self.isAtBottom)
                }
            })
            scroll.contentView.postsBoundsChangedNotifications = true
            tokens.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
            })
        }
        func detach() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
            scrollView = nil
            liveScrolling = false
        }
        private var isAtBottom: Bool {
            guard let scrollView, let document = scrollView.documentView else { return true }
            return document.bounds.maxY - scrollView.documentVisibleRect.maxY <= 24
        }
        private func boundsChanged() {
            guard let scrollView else { return }
            let y = scrollView.documentVisibleRect.minY
            let movedUp = y < previousY - 0.5
            previousY = y
            guard !liveScrolling else { return }
            let atBottom = isAtBottom
            // Keyboard and scrollbar jumps can change bounds without a live
            // scroll gesture. Defer state writes out of AppKit layout.
            if movedUp || atBottom {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.liveScrolling else { return }
                    if movedUp { self.parent.onScrollBegan() }
                    self.parent.onScrollEnded(atBottom)
                }
            }
        }
    }
}

private final class ScrollMarkerView: NSView {
    var onAttach: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.onAttach?() }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.onAttach?() }
    }
}

private struct MessageRow: View {
    let entry: ChatEntry
    @State private var copied = false
    private var isTool: Bool { entry.role == "tool" || entry.role == "system" }
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: entry.role == "user" ? "person.crop.circle" : isTool ? "terminal" : "sparkle")
                .font(.system(size: 15)).foregroundStyle(entry.role == "user" ? Color.secondary : Color.accentColor)
                .frame(width: 23, height: 22)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(entry.role == "user" ? "你" : isTool ? "执行记录" : "MyAgent").font(.system(size: 12, weight: .semibold))
                    Text(entry.createdAt, style: .time).font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("复制消息")
                }
                if isTool {
                    Text(entry.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text(.init(entry.text)).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GrowingPromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = PromptTextView(frame: .zero)
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 4, height: 6)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.setAccessibilityLabel("任务输入，Return 换行，Command Return 发送")
        editor.delegate = context.coordinator
        editor.onSend = onSend
        editor.onResize = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        scroll.documentView = editor
        context.coordinator.editor = editor
        editor.string = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PromptTextView else { return }
        editor.onSend = onSend
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        context.coordinator.measure()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingPromptEditor
        weak var editor: PromptTextView?
        private var isMeasuring = false
        init(_ parent: GrowingPromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            parent.text = editor.string
            measure()
        }
        func measure() {
            guard !isMeasuring, let editor, let container = editor.textContainer,
                  container.containerSize.width > 0, let layout = editor.layoutManager else { return }
            isMeasuring = true
            defer { isMeasuring = false }
            layout.ensureLayout(for: container)
            let height = min(180, max(60, ceil(layout.usedRect(for: container).height + editor.textContainerInset.height * 2)))
            guard abs(parent.measuredHeight - height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.measuredHeight = height }
        }
    }
}

private final class PromptTextView: NSTextView {
    var onSend: (() -> Void)?
    var onResize: (() -> Void)?
    private func isSendShortcut(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
            && !hasMarkedText()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isSendShortcut(event) {
            onSend?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if isSendShortcut(event) {
            onSend?()
        } else { super.keyDown(with: event) }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

private struct PermissionSheet: View {
    @ObservedObject var model: AppModel
    let request: PendingPermission
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("需要你的授权", systemImage: "hand.raised").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text(request.title).font(.system(size: 21, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("请求内容").font(.system(size: 12, weight: .semibold))
                        Text(request.detail)
                            .font(request.kind == "execution" ? .system(size: 12, design: .monospaced) : .system(size: 13))
                            .lineSpacing(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        detail("范围", request.scope)
                        detail("办公影响", request.kind == "desktop"
                               ? "使用 AX 对授权应用定向操作，不切换前台、不注入全局键鼠。等待空闲 3 秒；20 秒仍忙则暂停。"
                               : request.kind == "browser" ? "使用独立后台浏览器，不读取现有浏览器会话。" : "执行上方列明的项目操作。")
                        detail("授权时长", request.kind == "desktop" || request.kind == "browser"
                               ? "确认后同一范围内有效 90 秒；范围改变或到期后重新请求授权。" : "仅这一次明确列出的操作。")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }.padding(.trailing, 3)
            }.frame(maxHeight: 350)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(request.expiresAt.timeIntervalSince(context.date)))
                HStack {
                    Button("停止任务", role: .destructive, action: model.stop)
                        .keyboardShortcut(".", modifiers: .command)
                    Spacer()
                    Text(seconds > 0 ? "确认剩余 \(seconds) 秒" : "请求已过期").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("拒绝") { model.respondPermission(false) }.keyboardShortcut(.cancelAction)
                    Button("同意") { model.respondPermission(true) }.buttonStyle(.borderedProminent).disabled(seconds == 0)
                }
            }
        }.padding(27).frame(width: 560).interactiveDismissDisabled()
    }
    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

private struct ChoiceSheet: View {
    @ObservedObject var model: AppModel
    let choice: PendingChoice
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(choice.title).font(.system(size: 21, weight: .semibold))
            Text("查看交付物、下一步与办公影响，再选择继续方向。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if let error = model.lastError {
                HStack {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                    Button(action: model.clearError) { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            ScrollView {
                VStack(spacing: 13) {
                    ForEach(choice.options) { option in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(option.title).font(.system(size: 15, weight: .semibold))
                            Text(option.description).font(.system(size: 13)).foregroundStyle(.secondary)
                            if !option.deliverables.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("交付物").font(.system(size: 12, weight: .semibold))
                                    ForEach(Array(option.deliverables.enumerated()), id: \.offset) { _, item in
                                        Label(item, systemImage: "doc.text").font(.system(size: 12))
                                    }
                                }
                            }
                            ForEach(Array(option.previewPaths.enumerated()), id: \.offset) { _, path in
                                Button { model.previewPath(path) } label: { Label(path, systemImage: "doc.text.magnifyingglass").font(.system(size: 12)) }
                                    .buttonStyle(.link).multilineTextAlignment(.leading)
                            }
                            Divider()
                            Text("办公影响：\(option.impact)").font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 12) {
                                Text("下一步：\(option.nextStep)").font(.system(size: 12)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("选择此方案") { model.chooseOption(option.id) }.buttonStyle(.borderedProminent)
                            }
                        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)) }
                    }
                }.padding(.trailing, 3)
            }.frame(maxHeight: 570)
            HStack {
                Button("停止任务", role: .destructive, action: model.stop)
                    .keyboardShortcut(".", modifiers: .command)
                Spacer()
                Button("取消选择", action: model.declineChoice).keyboardShortcut(.cancelAction)
            }
        }.padding(26).frame(width: 670).interactiveDismissDisabled()
            .sheet(isPresented: $model.showPreview) { FilePreviewSheet(model: model) }
    }
}

private struct FilePreviewSheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.previewTitle, systemImage: "doc.text.magnifyingglass").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("完成") { model.showPreview = false }.keyboardShortcut(.cancelAction)
            }.padding(17)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                if let image = model.previewImage {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 920, maxHeight: 680).padding(20)
                } else {
                    Text(model.previewText.isEmpty ? "文件没有可显示的文本内容。" : model.previewText)
                        .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
        }.frame(minWidth: 640, idealWidth: 850, maxWidth: 1050, minHeight: 450, idealHeight: 650, maxHeight: 800)
    }
}
