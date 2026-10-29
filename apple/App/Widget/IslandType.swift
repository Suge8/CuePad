import SwiftUI

/// 紧凑态不随动态字体放大：固定三字符的读数槽，0…99 与 99+ 同宽，不挤状态栏；完整数在展开态。
nonisolated enum IslandType {
    static let count = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let countWidth: CGFloat = 32
    static let marker = Font.system(size: 12, weight: .semibold)
    static let markerWidth: CGFloat = 12
}
