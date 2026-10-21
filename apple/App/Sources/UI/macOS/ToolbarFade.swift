#if os(macOS)
import SwiftUI

/// 工具栏那一条（窗口顶到工具栏安全区的下沿）的页底色渐变：摆在安全区上沿、往上伸满那一条，不量尺寸。
struct ToolbarFade: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Color.clear.frame(height: 0)
            .background(alignment: .bottom) { TopFade(color: palette.desk).ignoresSafeArea(edges: .top) }
            .allowsHitTesting(false)
    }
}
#endif
