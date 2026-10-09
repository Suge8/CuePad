import CueStore
import SwiftUI

/// 改会话名（iOS 的 Agent 页与会话页、Mac 侧栏、Agent 整页与会话页共用）：一张小表单，输入框预填现在的名字、弹出即聚焦，
/// 确定后经 `AppServices.rename` 让 Pi 改（会话名只来自 Pi）。没改动或空着时"改名"停用——用系统工具栏按钮而不是提示框：
/// iOS 的提示框不画按钮的停用态，点不了也看不出来。
private struct RenameSheet: View {
    let target: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var changed: String? {
        guard let name = PiRename.clean(name), name != PiRename.clean(target.title) else { return nil }
        return name
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("会话名", text: $name)
                    .labelsHidden()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(commit)
            }
            .formStyle(.grouped)
            .navigationTitle("重命名会话")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("改名", action: commit).disabled(changed == nil) }
            }
        }
        #if os(iOS)
        .presentationDetents([.height(180)])
        #else
        .frame(width: 360)
        #endif
        .onAppear {
            name = target.title
            focused = true
        }
    }

    private func commit() {
        guard let name = changed else { return }
        let target = target, services = workspace.services
        workspace.attempt { try await services.rename(target, to: name) }
        dismiss()
    }
}

extension View {
    /// `session` 非空时弹出改名表单，关掉时置回 nil。
    func renameSession(_ session: Binding<PiSessionState?>) -> some View {
        sheet(item: session) { RenameSheet(target: $0) }
    }
}

extension MacDelivery {
    /// 能改名：读得到的会话（旧版扩展的收不到设置）；已结束的也能改，Mac 先在后台恢复它。
    static func canRename(_ session: PiSessionState) -> Bool { session.state != .known(.incompatible) }
}
