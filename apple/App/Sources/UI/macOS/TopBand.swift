#if os(macOS)
import SwiftUI

extension View {
    /// 量窗口最顶那一排（红绿灯与工具栏）有多高：页的上沿就是它的下沿。排进那一排的东西（看板的列头、项目页下滚后的回到顶部）按它定高、居中，
    /// 与工具栏的控件同一条中线。挂在页的根上。
    func readsTopBand(into band: Binding<CGFloat>) -> some View {
        background { Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { band.wrappedValue = $0 } }
    }
}
#endif
