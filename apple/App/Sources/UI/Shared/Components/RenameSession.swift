import CueStore
import SwiftUI

/// 改会话名（iOS 的 Agent 页与会话页、Mac 侧栏、Agent 整页与会话页共用）：一张小表单，输入框预填现在的名字、弹出即聚焦，
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
    /// `session` 非空时弹出改名表单，关掉时置回 nil。
    func renameSession(_ session: Binding<PiSessionState?>) -> some View {
        panel(item: session) { RenameSheet(target: $0) }
    }

    /// `session` 非空时问要不要结束它（两端的 Agent 页与会话页）：确认后经 `Workspace.end` 发给它所在的 Mac，对话留着。
    func endSession(_ session: Binding<PiSessionState?>) -> some View { modifier(EndSession(session: session)) }
}

private struct EndSession: ViewModifier {
    @Binding var session: PiSessionState?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content.dialog("结束这个会话？", item: $session, message: "对话会保留，再给它发消息会在后台恢复") { session in
            [DialogButton(title: "结束会话", role: .destructive) { Task { await workspace.end(session) } }]
        }
    }
}

extension MacDelivery {
    /// 能改名：读得到的会话（旧版扩展的收不到设置）；已结束的也能改，Mac 先在后台恢复它。
    static func canRename(_ session: PiSessionState) -> Bool { session.state != .known(.incompatible) }
}
