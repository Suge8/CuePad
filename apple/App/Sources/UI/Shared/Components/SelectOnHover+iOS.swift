#if os(iOS)
import SwiftUI

extension View {
    /// 会话里的文字可选中（Mac 只在悬停的那一条开选择，见 `SelectOnHover+macOS`）。
    func selectableOnHover() -> some View { textSelection(.enabled) }
}
#endif
