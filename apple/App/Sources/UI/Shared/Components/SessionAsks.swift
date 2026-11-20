import CueStore
import SwiftUI

/// "改名"停用时用系统工具栏按钮而不是提示框：iOS 的提示框不画按钮的停用态，点不了也看不出来。
private struct RenameSheet: View {
    let target: SessionState
    let shown: String
    let adopts: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @State private var name = ""
    @FocusState private var focused: Bool

    private var changed: String? {
        guard let name = SessionRename.clean(name), name != SessionRename.clean(shown) else { return nil }
        return name
    }

    var body: some View {
        content.onAppear {
            name = shown
            focused = true
        }
    }

    private var field: some View {
        TextField("会话名", text: $name)
            .labelsHidden()
            .focused($focused)
            .submitLabel(.done)
            .onSubmit(commit)
            // 会话名是标识（atlas、deploy-2），不是句子：自动更正会把 atlas 改成 atlas’s，首字母大写也不对
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    #if os(iOS)
    private var content: some View {
        NavigationStack {
            Form { field }
                .formStyle(.grouped)
                .navigationTitle("重命名会话")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { close() } }
                    ToolbarItem(placement: .confirmationAction) { Button("改名", action: commit).disabled(changed == nil) }
                }
        }
        .presentationDetents([.height(180)])
    }
    #else
    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.block) {
            Text("重命名会话").font(Typography.bodyStrong)
            field.textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }
                Button("改名", action: commit).keyboardShortcut(.defaultAction).disabled(changed == nil)
            }
        }
        .padding(Spacing.panel)
        .frame(width: 360)
    }
    #endif

    private func commit() {
        guard let name = changed else { return }
        let target = target, adopts = adopts, workspace = workspace
        workspace.attempt { try await workspace.rename(target, to: name, adopts: adopts) }
        close()
    }
}

extension View {
    /// 手机上结束的确认是居中的提示框：从菜单里点出来的，没有那颗钮可以指（iPad 上动作表要指向一处）。
    func sessionAsks(_ workspace: Workspace) -> some View { modifier(SessionAsks(workspace: workspace)) }
}

private struct SessionAsks: ViewModifier {
    @Bindable var workspace: Workspace

    func body(content: Content) -> some View {
        content
            .panel(item: renaming) { RenameSheet(target: $0.session, shown: $0.shown, adopts: $0.adopts) }
            .modifier(CompletionAsks(workspace: workspace, spot: .window))
        #if os(macOS)
            .dialog(Self.title, item: asked { if case .end(let session) = $0 { session } else { nil } }, message: Self.message) { session in
                [DialogButton(title: "休眠") { end(session) }]
            }
        #else
            .alert(Text(Self.title), isPresented: Binding { ending != nil } set: { if !$0 { workspace.sessionAsk = nil } }, presenting: ending) { session in
                Button("休眠") { end(session) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text(Self.message)
            }
        #endif
    }

    private static let title: LocalizedStringResource = "Agent 还在做事，让它休眠？"
    private static let message: LocalizedStringResource = "手上这一步会被打断。对话会保留，再对它说话就醒"

    private struct Renaming: Identifiable {
        let session: SessionState
        let shown: String
        let adopts: Bool
        var id: UUID { session.id }
    }

    private var renaming: Binding<Renaming?> {
        Binding {
            if case .rename(let session, let shown, let adopts) = workspace.sessionAsk { Renaming(session: session, shown: shown, adopts: adopts) } else { nil }
        } set: {
            if $0 == nil, case .rename = workspace.sessionAsk { workspace.sessionAsk = nil }
        }
    }

    private var ending: SessionState? { if case .end(let session) = workspace.sessionAsk { session } else { nil } }

    private func end(_ session: SessionState) { Task { await workspace.end(session) } }

    /// 这一种在问时是它的会话；关掉时只清自己这一种（另一种已经换上来就不动）。
    private func asked(_ pick: @escaping (SessionAsk) -> SessionState?) -> Binding<SessionState?> {
        Binding { workspace.sessionAsk.flatMap(pick) } set: { if $0 == nil, workspace.sessionAsk.flatMap(pick) != nil { workspace.sessionAsk = nil } }
    }
}

extension View {
    /// 正显示这张卡完成圈（或看板卡）的视图挂它，认领这张卡的完成问句（`Workspace.confirmComplete`）：问的是这张卡时挨着这里弹出，
    /// 同一张卡同时显示在几处时最后出现的那一处认领。`task` 为 nil 时不认领。Mac 不认领：确认框本来就在窗口居中（`dialog`），挂在哪里都一样，省得每个圈都挂一份。
    func completionAsks(claiming task: UUID?) -> some View {
        #if os(iOS)
        modifier(CompletionClaim(task: task))
        #else
        self
        #endif
    }
}

private struct CompletionClaim: ViewModifier {
    let task: UUID?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        if let task { content.modifier(CompletionAsks(workspace: workspace, spot: .claim(task))) } else { content }
    }
}

/// 完成前那一问只有这一份：挂在认领者上（`claim`）或窗口上（`window`，出没人认领的）。
private struct CompletionAsks: ViewModifier {
    enum Spot: Equatable { case window, claim(UUID) }

    let workspace: Workspace
    let spot: Spot
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .agentBusyDialog(busy?.session, sleeps: busy?.sleeps ?? true, isPresented: asking { if case .agent = $0 { true } else { false } }, confirm: confirm)
            .ask(.verbatim(TaskCopy.openSubtasks(steps)), isPresented: asking { if case .steps = $0 { true } else { false } },
                 button: DialogButton(title: "全部完成", action: confirm))
            .onAppear {
                guard case .claim(let task) = spot else { return }
                workspace.completionClaims[task, default: []].append(token)
            }
            .onDisappear {
                guard case .claim(let task) = spot else { return }
                workspace.completionClaims[task]?.removeAll { $0 == token }
                if workspace.completionClaims[task]?.isEmpty == true { workspace.completionClaims[task] = nil }
                // 问着的时候认领它的视图没了（列表收起、换页）：这一问作罢，同取消
                if mine != nil { workspace.sessionAsk = nil }
            }
    }

    private var mine: CompletionAsk? {
        guard case .complete(let ask, let claimer, _) = workspace.sessionAsk else { return nil }
        return claimer == (spot == .window ? nil : token) ? ask : nil
    }

    private var busy: (session: SessionState, sleeps: Bool)? { if case .agent(let session, let sleeps) = mine { (session, sleeps) } else { nil } }
    private var steps: TaskProgress? { if case .steps(let progress) = mine { progress } else { nil } }

    /// 关掉时只清自己这一种（另一种已经换上来就不动）。
    private func asking(_ kind: @escaping (CompletionAsk) -> Bool) -> Binding<Bool> {
        Binding { mine.map(kind) ?? false } set: { if !$0, mine.map(kind) == true { workspace.sessionAsk = nil } }
    }

    /// 取的是呈现时那一问的：按下时框可能已先收起、`sessionAsk` 已清。
    private var confirm: @MainActor () -> Void {
        guard mine != nil, case .complete(_, _, let proceed) = workspace.sessionAsk else { return {} }
        return { [workspace] in workspace.answer(proceed) }
    }
}
