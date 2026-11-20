import SwiftUI

/// 紧凑态不随动态字体放大：读数 0…99 与 99+、钟到 "1:02:45" 都排得进系统给一侧的 52pt 上下，不挤状态栏；完整数在展开态。
nonisolated enum IslandType {
    static let count = Font.system(size: 15, weight: .semibold, design: .rounded)
    /// 紧凑态右位的钟定宽（放得下 "59:59"）：岛的右缘不随秒数伸缩，过一小时收字号。系统给一侧 52pt 上下，再宽就挤掉状态栏的图标。
    static let clockWidth: CGFloat = 44
    /// 展开态行尾那只钟的宽（放得下 "59:59"）：各行的图形对成一列，过一小时收字号。
    static let rowClockWidth: CGFloat = 36
    static let marker = Font.system(size: 12, weight: .semibold)
    static let narrowSide: CGFloat = 28
    static let narrowMarker: CGFloat = 9
    static let narrowNumberHeight: CGFloat = 17
    static let reading = Font.system(size: 28, weight: .bold, design: .rounded)
    static let readingGlyph = Font.system(size: 17, weight: .bold)
    static let clock = Font.system(size: 28, weight: .bold, design: .rounded)
    /// 紧凑态右位等你时那颗实色胶囊里的钟：字宽加两边的留白仍在 52pt 以内。
    static let chipClock = Font.system(size: 14, weight: .bold, design: .rounded)
    static let chipClockWidth: CGFloat = 38
    static let question = Font.system(size: 16, weight: .bold)
    static let row = Font.system(size: 15, weight: .medium)
    static let rowTail = Font.system(size: 14, weight: .semibold, design: .rounded)

    // 锁屏那张卡：系统封顶 160pt 高，字号钉死，不随动态字体放大（放大了排不下，被裁掉的是最后几行）。
    static let posterTitle = Font.system(size: 20, weight: .bold)
    static let posterQuestion = Font.system(size: 17, weight: .bold)
    static let posterBig = Font.system(size: 44, weight: .bold, design: .rounded)
    static let posterWord = Font.system(size: 14, weight: .bold)
    static let posterHeadWord = Font.system(size: 17, weight: .bold)
    static let posterRow = Font.system(size: 14.5, weight: .semibold)
    static let posterTime = Font.system(size: 14.5, weight: .semibold, design: .rounded)
    static let posterGlyph = Font.system(size: 13, weight: .semibold)
    static let posterTick = Font.system(size: 20, weight: .bold)
    /// 行尾那只钟的宽（放得下 "59:59"），过一小时收字号。
    static let posterTimeWidth: CGFloat = 42
}
