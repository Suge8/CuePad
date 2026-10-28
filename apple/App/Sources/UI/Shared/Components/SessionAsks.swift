import CueStore
import SwiftUI

/// 改会话名（`SessionActions` 的"重命名"，窗口上那一格弹出，`sessionAsks`）：一张小表单，输入框预填现在的名字、弹出即聚焦，
/// 确定后经 `AppServices.rename` 让 Pi 改（会话名只来自 Pi）。没改动或空着时"改名"停用——用系统工具栏按钮而不是提示框：
/// iOS 的提示框不画按钮的停用态，点不了也看不出来。
private struct RenameSheet: View {
    let target: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @State private var name = ""
    @FocusState private var focused: Bool

    private var changed: String? {
        guard let name = PiRename.clean(name), name != PiRename.clean(target.title) else { return nil }
        return name
    }

    var body: some View {
        content.onAppear {
            name = target.title
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
    /// 同项目表单：标题、输入框、右下取消与改名（↩ 改名，Esc 由弹层接）。
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名会话").font(Typography.bodyStrong)
            field.textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }
                Button("改名", action: commit).keyboardShortcut(.defaultAction).disabled(changed == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(palette.desk)
    }
    #endif

    private func commit() {
        guard let name = changed else { return }
        let target = target, services = workspace.services
        workspace.attempt { try await services.rename(target, to: name) }
        close()
    }
}

extension View {
    /// 窗口上弹会话确认的那一格（`Workspace.sessionAsk`）：改名弹表单；结束先问一句，确认后经 `Workspace.end` 发给它所在的 Mac，对话留着。
    /// 手机上结束的确认是居中的提示框：从菜单里点出来的，没有那颗钮可以指（iPad 上动作表要指向一处）。
    func sessionAsks(_ workspace: Workspace) -> some View { modifier(SessionAsks(workspace: workspace)) }
}

private struct SessionAsks: ViewModifier {
    @Bindable var workspace: Workspace

    func body(content: Content) -> some View {
        content
            .panel(item: asked { if case .rename(let session) = $0 { session } else { nil } }) { RenameSheet(target: $0) }
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

    private var ending: PiSessionState? { if case .end(let session) = workspace.sessionAsk { session } else { nil } }

    private func end(_ session: PiSessionState) { Task { await workspace.end(session) } }

    /// 这一种在问时是它的会话；关掉时只清自己这一种（另一种已经换上来就不动）。
    private func asked(_ pick: @escaping (SessionAsk) -> PiSessionState?) -> Binding<PiSessionState?> {
        Binding { workspace.sessionAsk.flatMap(pick) } set: { if $0 == nil, workspace.sessionAsk.flatMap(pick) != nil { workspace.sessionAsk = nil } }
    }
}

extension MacDelivery {
    /// 能改名：做得到（`AgentCapabilities.rename`）；已结束的也能改，Mac 先在后台恢复它。
    static func canRename(_ session: PiSessionState) -> Bool { session.capabilities.contains(.rename) }
}
