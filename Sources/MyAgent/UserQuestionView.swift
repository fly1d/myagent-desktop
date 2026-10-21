import SwiftUI

/// A suggestion fills the answer editor; only explicit submission resumes work.
struct UserQuestionView: View {
    @ObservedObject var model: AppModel
    let question: PendingQuestion
    @State private var answer = ""

    private let maximumLength = 4_000
    private var canSubmit: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answer.count <= maximumLength
    }
    private var answerBinding: Binding<String> {
        Binding(get: { answer }, set: { answer = String($0.prefix(maximumLength)) })
    }
    private var suggestions: [String] {
        question.options.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                Label("需要你的补充", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                Spacer()
                Button(action: dismissIfCurrent) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("暂不回答")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Text(question.question).font(.system(size: 21, weight: .semibold))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !question.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(question.context).font(.system(size: 13)).foregroundStyle(.secondary)
                            .lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("建议答案").font(.system(size: 12, weight: .semibold))
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                                Button { answer = String(suggestion.prefix(maximumLength)) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(suggestion).font(.system(size: 13)).multilineTextAlignment(.leading)
                                            .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "arrow.down.left").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }.padding(.vertical, 3)
                                }.buttonStyle(.bordered).help("填入下方编辑器，不会自动提交")
                            }
                            Text("点击只会填入，你可以自由修改，也可以直接写自己的回答。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.trailing, 3)
            }.frame(maxHeight: 220)
            VStack(alignment: .leading, spacing: 8) {
                Text("你的回答").font(.system(size: 12, weight: .semibold))
                ZStack(alignment: .topLeading) {
                    if answer.isEmpty {
                        Text(question.placeholder.isEmpty ? "输入你的回答…" : question.placeholder)
                            .font(.system(size: 14)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.vertical, 9).allowsHitTesting(false)
                    }
                    TextEditor(text: answerBinding).font(.system(size: 14))
                        .scrollContentBackground(.hidden).padding(4)
                        .frame(height: 120).accessibilityLabel("你的回答")
                }.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14)) }
                HStack {
                    Text(answer.count == maximumLength ? "已达到字符上限，可修改后提交。" : "最多 4,000 个字符")
                    Spacer()
                    Text("\(answer.count) / 4,000").monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("停止任务", role: .destructive, action: model.stop)
                    .keyboardShortcut(".", modifiers: .command)
                Spacer()
                Button("暂不回答", action: dismissIfCurrent).keyboardShortcut(.cancelAction)
                Button("提交并继续") {
                    guard canSubmit, model.pendingQuestion?.id == question.id else { return }
                    model.answerQuestion(answer)
                }.buttonStyle(.borderedProminent).disabled(!canSubmit || model.pendingQuestion?.id != question.id)
            }
        }.font(.system(size: 14)).padding(27).frame(width: 610)
            .interactiveDismissDisabled()
            .onDisappear(perform: dismissIfCurrent)
    }

    private func dismissIfCurrent() {
        if model.pendingQuestion?.id == question.id { model.dismissQuestion() }
    }
}
