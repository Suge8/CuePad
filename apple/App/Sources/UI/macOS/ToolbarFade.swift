#if os(macOS)
import SwiftUI

/// 工具栏那一条（窗口顶到工具栏安全区的下沿）的页底色渐变：摆在安全区上沿、往上伸满那一条，不量尺寸。
/// 任务页（没开编辑页时）不垫这一条：它的列头就排在这一条里，渐变由各列自己垫在列头下面（`boardTopRow`）。
struct ToolbarFade: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let own = workspace.root == .tasks && workspace.openCard == nil
        Color.clear.frame(height: 0)
            .background(alignment: .bottom) { if !own { TopFade(color: palette.desk).ignoresSafeArea(edges: .top) } }
            .allowsHitTesting(false)
    }
}
#endif
