import SwiftUI

/// 全 App 的圆角只有这几档，按"是什么"取；Theme 以外不写圆角的数（`lint.sh` 查）。胶囊与圆用系统的 `.capsule`、`.circle`，不写半高。
/// 档与档之间差得够开：新东西先问它是哪一类，不另配一个数。
nonisolated enum Radius {
    /// 小物件：键帽、行内小块、小缩略图。
    static let chip: CGFloat = 6
    /// 嵌在纸与面板里的块：图片、代码块、输入条、设置里的分组块，Mac 上由行拼成的纸与任务看板卡。
    static let block: CGFloat = 12
    /// 卡片与浮层：灵感卡、手机的看板卡、面板、搜索框、提示条。
    static let card: CGFloat = 16
    /// 大块面：气泡、手机上的分组纸、空态、Cue 条。看板列的托盘也是它，卡与托盘留 `BoardCardMetrics.inset` 的边、近似同心。
    static let sheet: CGFloat = 22
    /// 输入框与手机的任务气泡：输入框单行高 `ComposerMetrics.slot`，正好是它的两倍。
    static let field: CGFloat = 28
    /// 贴在手机屏幕底部的纸：屏幕圆角减去留的边，与屏幕同心。
    static let screen: CGFloat = 46
    /// 列表行底的下限（`Rows.swift`）：Mac 的行矮，手机的行与块同高一档。
    #if os(iOS)
    static let row = block
    #else
    static let row: CGFloat = 8
    #endif

    /// 嵌在容器里的块（容器用 `containerShape`、`rowContainer` 声明）：四角与容器同心，内角随外角走、不手算；离容器角远的角取 `block`。
    static var nested: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: .fixed(block))) }
}
