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
    static let reading = Font.system(.title2, design: .rounded, weight: .semibold)
    static let readingGlyph = Font.system(.headline, weight: .semibold)
    static let clock = Font.system(.title3, design: .rounded, weight: .semibold)
}
