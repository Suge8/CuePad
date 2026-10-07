#if os(iOS)
import CueStore
import SwiftUI
import UIKit

/// 任务浮窗里的一页：任务就是给 Agent 的话。顶上一行是状态与所在项目；中间是正文（第一行是标题，之后是要求），
/// 贴着正文右下是"交给 Agent"，只有标题时左边一句"写下要 Agent 做什么…"；下面两行次要信息——Agent（交给的会话此刻
/// 在做什么、发出过几次）与下级（子任务与素材），各自点进去。写字时（键盘出来）只留正文，键盘上方的工具栏也能交给 Agent。
struct TaskPage<Editor: View, Actions: View>: View {
    let card: Card
    let project: Project?
    /// 正文（含还没存下的）除了标题还有没有要求。
    let written: Bool
    /// 交给 Agent：带上选中的挂着的灵感与资料（`BundlePicker`）。
    let hand: (_ parts: [Card]) -> Void
    let continuePrompt: () -> Void
    @ViewBuilder let editor: Editor
    @ViewBuilder let actions: Actions
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: TaskDetail?
    @State private var typing = false
    @State private var showsSends = false
    @State private var showsChildren = false
    @State private var left: Set<UUID> = []
    @State private var withResources = false

    private static var inset: CGFloat { 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text("给 Agent 的话").font(.caption.weight(.medium)).foregroundStyle(palette.ink3)
                .padding(.horizontal, Self.inset).padding(.top, 12)
                .accessibilityHidden(true)
            editor
                .overlay(alignment: .bottom) { if !typing { promptBar.transition(.opacity) } }
            if !typing {
                VStack(spacing: 0) {
                    Divider().overlay(palette.hair)
                    TaskAgentStrip(detail: detail) { showsSends = true }
                    Divider().overlay(palette.hair)
                    TaskSubitemsRow(detail: detail, expanded: false) { showsChildren = true }
                }
                .padding(.horizontal, Self.inset).padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .background(palette.paper)
        .toolbar(.hidden, for: .navigationBar)
        .animation(Motion.spatial(Motion.quick, reduceMotion: reduceMotion), value: typing)
        .navigationDestination(isPresented: $showsSends) { sendsPage }
        .navigationDestination(isPresented: $showsChildren) { childrenPage }
        .observing(services.store, TaskDetail.tables, id: card.id, into: $detail, onError: workspace.fail) { [id = card.id] in
            try TaskDetail.read(id, from: $0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in typing = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in typing = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            TaskStatusMenu(task: card, marks: detail?.marks)
            TaskProjectMenu(task: card, project: project).font(.subheadline)
            Spacer(minLength: 8)
            Menu("更多", systemImage: "ellipsis") { actions }
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold)).foregroundStyle(palette.ink2)
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .padding(.leading, Self.inset).padding(.trailing, 8).padding(.top, 14)
    }

    /// 贴着正文的底边：只有标题时的引导，右边是交给 Agent；有挂着的灵感或本项目资料时，上面一行选一并带上哪些。
    private var promptBar: some View {
        VStack(alignment: .trailing, spacing: 6) {
            BundlePicker(detail: detail, left: $left, withResources: $withResources)
                .padding(.leading, Self.inset)
            handRow
        }
        .padding(.bottom, 12)
    }

    private var handRow: some View {
        HStack(spacing: 8) {
            if !written { PromptHint(action: continuePrompt) }
            Spacer(minLength: 8)
            AgentHandButton { hand(BundlePicker.parts(detail, left: left, withResources: withResources)) }
                .accessibilityHint(written ? "把这段话发给 Mac 上的 Agent 会话" : "还只有标题，也可以先发出去")
        }
        .padding(.leading, Self.inset).padding(.trailing, 16)
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

    private var childrenPage: some View {
        ScrollView {
            TaskChildrenList(task: card, detail: detail)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(palette.paper, in: .rect(cornerRadius: 16, style: .continuous))
                .padding(16)
        }
        .deskBackground()
        .navigationTitle(detail?.subitemsSummary ?? "下级")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 交给 Agent 的主按钮：墨色胶囊，贴着正文右下（任务浮窗与灵感纸页同一颗）。
struct AgentHandButton: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Label("交给 Agent", systemImage: "paperplane.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.paper)
                .padding(.horizontal, 16).frame(height: 40)
                .background(palette.ink, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
    }
}
#endif
