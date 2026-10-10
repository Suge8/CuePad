#if os(iOS)
import SwiftUI

// 键盘弹出模型与思考强度菜单只有 Mac（⌘⇧M、⌘⇧E）；手机上没有这个入口。
extension PiConfigControls {
    func open(_ pick: PiConfigPick) {}
}

final class PopUpAnchor {}

extension View {
    func popUpAnchor(_ anchor: PopUpAnchor?) -> some View { self }
}
#endif
