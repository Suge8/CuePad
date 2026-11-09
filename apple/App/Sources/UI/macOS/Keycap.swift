#if os(macOS)
import SwiftUI

/// 键帽：快捷键在界面上只有这一种写法（设置里显示或隐藏 CuePad 的快捷键、⌘K 面板的 esc）。
struct Keycap: View {
    let text: String
    @Environment(\.palette) private var palette
    /// 键帽贴着字、比任何一档控件都小，不随间距档。
    private static let padding = EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5)

    var body: some View {
        Text(text)
            .font(Typography.keycap)
            .foregroundStyle(palette.ink2)
            .padding(Self.padding)
            .background(palette.fill, in: .rect(cornerRadius: Radius.chip))
    }
}
#endif
