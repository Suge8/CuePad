import SwiftUI

/// 图标的尺寸与字重的唯一来源（图标按字号画，字号就是图标的大小）；Theme 以外不写 `.system(size:)`（`lint.sh` 查）。
/// 档按图标在界面里的位置分，档与档差得够开：新图标先问它属于哪一档，不另配一个数。图标随字号、不随动态字体：旁边的字用 `Typography`。
/// 个别处要比档再粗一档，在调用处写 `.weight(…)`，不另开一档。
nonisolated enum Glyph {
    /// 小记号：展开与前进的小箭头、角标里的小图标。
    static let mark = Font.system(size: 9, weight: .bold)
    /// 小钮与行内的图标：收起钮、新任务的加号、行尾的状态。
    static let small = Font.system(size: 12, weight: .semibold)
    /// 列表行首与区头动作的图标。
    static let rowSize: CGFloat = 13
    static let row = Font.system(size: rowSize, weight: .medium)
    /// 侧栏脚部、工具栏圆钮、头像串里的图标。
    static let control = Font.system(size: 15)
    /// 大图标：手机底栏的"更多"、选中的角标、菜单栏图标。
    static let largeSize: CGFloat = 20
    static let large = Font.system(size: largeSize)
    /// 没有预览时占位的大图标。
    static let hero = Font.system(size: 56)
}
