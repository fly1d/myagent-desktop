import SwiftUI

@main
struct MyAgentApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .frame(minWidth: 1000, minHeight: 680)
                .task { await model.connect() }
        }
        .defaultSize(width: 1380, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建任务") { model.newTask() }.keyboardShortcut("n")
                Button("选择项目目录…") { model.chooseWorkspace() }.keyboardShortcut("o")
            }
            CommandMenu("Agent") {
                Button("停止当前执行") { model.stop() }.keyboardShortcut(".")
                Button("重新连接执行引擎") { Task { await model.reconnect() } }
            }
        }
        Settings { PreferencesView(model: model).frame(width: 620, height: 520) }
    }
}
