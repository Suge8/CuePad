#if os(iOS)
import CueStore
import SwiftUI
import UIKit

/// 任务浮窗里的一页，三块：
/// ① 标题行：左边完成圈（点它完成），正文第一行就是标题，右上"⋯"（项目、发出记录、复制、改回灵感、归档、删除）；
/// ② 给 Agent 的话：正文是焦点，只有标题时贴着它一句"写下要 Agent 做什么…"；底部唯一主按钮"交给 Agent"，
///    有相关灵感或本项目资料时按钮上面一行可勾的小胶囊（`BundlePicker`），没有就不出现；
/// ③ 进展：交给的会话与子任务、相关灵感合成一个清单，"＋"加子任务或灵感（`TaskProgressList`）。
/// 写字时（键盘出来）只留正文，键盘上方的工具栏也能交给 Agent。
struct TaskPage<Editor: View>: View {
    let card: Card
    /// 正文（含还没存下的）除了标题还有没有要求。
    let written: Bool
    /// 交给 Agent：带上选中的相关灵感与资料。
    let hand: (_ parts: [Card]) -> Void
    let continuePrompt: () -> Void
    @ViewBuilder let editor: Editor
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: TaskDetail?
    @State private var typing = false
    @State private var showsSends = false
    @State private var left: Set<UUID> = []
    @State private var withResources = false

    private static var inset: CGFloat { 20 }
    /// 进展一块最多占这么高，多了在块里滚。
    private static var progressHeight: CGFloat { 190 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                TaskRingButton(task: card, marks: detail?.marks).padding(.leading, 6).padding(.top, 14)
                editor
            }
            .overlay(alignment: .topTrailing) { more.padding(.top, 10).padding(.trailing, 8) }
            .overlay(alignment: .bottomLeading) {
                if !typing, !written { PromptHint(action: continuePrompt).padding(.leading, Self.inset + 30).padding(.bottom, 4) }
            }
            if !typing {
                VStack(alignment: .leading, spacing: 8) {
                    BundlePicker(detail: detail, left: $left, withResources: $withResources)
                    AgentHandButton { hand(BundlePicker.parts(detail, left: left, withResources: withResources)) }
                        .accessibilityHint(written ? "把这段话交给 Mac 上的 Agent 会话" : "还只有标题，也可以先交出去")
                }
                .padding(.horizontal, Self.inset).padding(.vertical, 10)
                .transition(.opacity)
                Divider().overlay(palette.hair)
                ScrollView {
                    TaskProgressList(task: card, detail: detail).padding(.horizontal, Self.inset).padding(.vertical, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.progressHeight)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .background(palette.paper)
        .toolbar(.hidden, for: .navigationBar)
        .animation(Motion.spatial(Motion.quick, reduceMotion: reduceMotion), value: typing)
        .navigationDestination(isPresented: $showsSends) { sendsPage }
        .observing(services.store, TaskDetail.tables, id: card.id, into: $detail, onError: workspace.fail) { [id = card.id] in
            try TaskDetail.read(id, from: $0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in typing = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in typing = false }
    }

    private var more: some View {
        Menu("更多", systemImage: "ellipsis") { CardActions(card: card, more: true) { showsSends = true } }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold)).foregroundStyle(palette.ink2)
            .frame(width: 44, height: 44).contentShape(.rect)
    }

    private var sendsPage: some View {
        List {
            SendRecordList(records: detail?.sends ?? [])
                .listRowBackground(palette.paper)
        }
        .deskBackground()
        .navigationTitle("发出记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 交给 Agent 的主按钮：一整条朱砂胶囊（签名色只落在主动作上），在任务浮窗正文下面、灵感纸页右下。
struct AgentHandButton: View {
    var fullWidth = true
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Label("交给 Agent", systemImage: "paperplane.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(palette.onSignature)
                .padding(.horizontal, 18).frame(maxWidth: fullWidth ? .infinity : nil).frame(height: 48)
                .background(palette.signature, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: 0)
    }
}
#endif
