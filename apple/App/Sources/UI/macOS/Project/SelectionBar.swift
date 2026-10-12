#if os(macOS)
import SwiftUI

/// 批量选择时替下底部输入栏的一条玻璃操作栏：选了几条、全选、删除（⌫，提示里可撤销）、完成（Esc）。
struct SelectionBar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let presses = workspace.presses
        let count = presses.selected.count
        HStack(spacing: 16) {
            Text("已选 \(count) 条").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink).monospacedDigit()
            Button("全选") { presses.selectAll() }
                .keyboardShortcut("a")
                .disabled(Set(presses.selectable).isSubset(of: presses.selected))
            Spacer(minLength: 8)
            Button("完成") { presses.clearSelection() }
                .keyboardShortcut(.cancelAction)
            Button(role: .destructive) { delete() } label: {
                Label("删除", systemImage: "trash")
                    .font(Typography.secondary.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(palette.failure, in: .capsule)
                    .contentShape(.capsule)
            }
            .keyboardShortcut(.delete, modifiers: [])
            .help("删除选中的 \(count) 条（⌫），可撤销")
        }
        .buttonStyle(PressStyle())
        .font(Typography.secondary)
        .foregroundStyle(palette.ink2)
        .padding(.leading, 20).padding(.trailing, 8)
        .frame(width: 460, height: 48)
        .glass(in: .capsule, interactive: true, ink: .solid)
    }

    private func delete() {
        let ids = Array(workspace.presses.selected)
        workspace.presses.clearSelection()
        workspace.attempt { try await workspace.trash(ids) }
    }
}
#endif
