#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

/// 键帽：快捷键在界面上只有这一种写法（设置里显示或隐藏 CuePad 的快捷键、⌘K 面板的 esc）。
struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.keycap)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
    }
}

#endif
