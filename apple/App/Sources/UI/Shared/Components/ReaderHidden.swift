import SwiftUI

extension View {
    /// 按条件不进读屏：看不见的那层、那段，占位的空行，换态时藏起的备选。iOS 上 `accessibilityHidden` 只在显式的无障碍容器里生效——
    /// 直接挂在 ZStack、HStack 里，或自己收成一个元素再挂，旁白照样逐个念到，透明度为 0 的也一样（模拟器旁白实测）；
    /// 所以给它包一层只装它自己的容器，不依赖上面有没有。Mac 的无障碍树照直接写法就藏得住（bcu 实测），Mac 独有的文件照直接写。
    /// 已合并成一个元素（`children: .combine`）里的那一句照直接写：合并元素里藏得住，这层容器反而把它挡在合并之外。
    func readerHidden(_ hidden: Bool) -> some View {
        ZStack { accessibilityHidden(hidden) }.accessibilityElement(children: .contain)
    }
}
