#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

/// 键帽：快捷键在界面上只有这一种写法（设置里显示或隐藏 CuePad 的快捷键、⌘K 面板的 esc）。
struct Keycap: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(Typography.keycap)
            .foregroundStyle(palette.ink2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(palette.fill, in: .rect(cornerRadius: 4))
    }
}

#endif
