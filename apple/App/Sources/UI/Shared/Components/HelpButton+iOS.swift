#if os(iOS)
import SwiftUI

/// 系统导航栏里的问号（推入页与 sheet 的栏项：技能与规则、记忆与定时；全 App 栏里弹说明的只有它）：系统 popover，紧凑尺寸下也不退成 sheet，
/// 由系统从栏项定位、箭头指着它，配色与说明气泡同一张纸（`Palette.paper`）。
/// 否决过：画在窗口那一层的气泡（`bubble`）——栏里的项是系统按 SwiftUI 的按钮另建的，建好之后不再跑它上面的 `onChange`，SwiftUI 量的框也对不上，
/// 按读屏标识在窗口里找（iOS 26 起栏项的视图不带标识）又找不到，气泡没有来源、没尾巴，压在页面第一行上。popover 的锚点是系统自己的栏项，不靠量。
/// 内容在 popover 自己的视图体里求值：开着时跟着数据变。
struct BarHelpButton<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var open = false
    @Environment(\.palette) private var palette

    /// 说明的宽：同纸与面板上问号的说明气泡（`CueListHelp`）。
    private static var width: CGFloat { 292 }

    var body: some View {
        Button("说明", icon: .help) { open.toggle() }
            .debugOpensHelp { open = true }
            .popover(isPresented: $open, arrowEdge: .top) {
                content()
                    .frame(width: Self.width, alignment: .leading)
                    .dynamicTypeSize(...PanelHost.largestType)
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(palette.paper)
            }
    }
}
#endif
