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
            .agentBusyDialog(completing, isPresented: Binding { completing != nil } set: { if !$0, completing != nil { workspace.sessionAsk = nil } }) {
                [workspace, completing] in
                guard let completing else { return }
                workspace.attempt { try await workspace.confirmFinish(completing) }
            }
        #if os(macOS)
            .dialog(Self.title, item: asked { if case .end(let session) = $0 { session } else { nil } }, message: Self.message) { session in
                [DialogButton(title: "结束会话", role: .destructive) { end(session) }]
            }
        #else
            .alert(Text(Self.title), isPresented: Binding { ending != nil } set: { if !$0 { workspace.sessionAsk = nil } }, presenting: ending) { session in
                Button("结束会话", role: .destructive) { end(session) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text(Self.message)
            }
        #endif
    }

    private static let title: LocalizedStringResource = "结束这个会话？"
    private static let message: LocalizedStringResource = "对话会保留，再给它发消息会在后台恢复"

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

    private var completing: SessionState? { if case .complete(let session) = workspace.sessionAsk { session } else { nil } }
    private var ending: SessionState? { if case .end(let session) = workspace.sessionAsk { session } else { nil } }

    private func end(_ session: SessionState) { Task { await workspace.end(session) } }

    /// 这一种在问时是它的会话；关掉时只清自己这一种（另一种已经换上来就不动）。
    private func asked(_ pick: @escaping (SessionAsk) -> SessionState?) -> Binding<SessionState?> {
        Binding { workspace.sessionAsk.flatMap(pick) } set: { if $0 == nil, workspace.sessionAsk.flatMap(pick) != nil { workspace.sessionAsk = nil } }
    }
}
