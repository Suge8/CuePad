#if os(macOS)
import SwiftUI

extension View {
    /// Mac 页面顶上那一排（项目范围、搜索、新建……）：钉在工具栏下面，玻璃控件浮在内容上，内容滚到它与工具栏后面、从按钮之间透出来（规矩在 `Bars`）。
    /// 那一排按工具栏的安全区摆；内容按加了这一排高度的安全区摆，滚动区照样铺到窗口顶，静止时第一行在这一排下面。
    /// 要透过这一排，页面的滚动区得挂在这个修饰里面、上沿不加内边距（内边距会把滚动区挤出安全区）。
    func pageHeader(@ViewBuilder _ row: () -> some View) -> some View {
        safeAreaInset(edge: .top, spacing: Bars.contentGap) {
            row()
                .frame(minHeight: Spacing.toolbarControl)
                .padding(.horizontal, Spacing.page).padding(.top, Bars.contentGap)
        }
    }
}

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
