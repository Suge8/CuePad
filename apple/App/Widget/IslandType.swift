import SwiftUI

/// 灵动岛紧凑态的字：岛的两侧是摄像头两边定宽的窄条，字号按那一条的宽度定死、不随动态字体（主 App 的字在 `Typography`，扩展里没有它）。
nonisolated enum IslandType {
    /// 一项着色的数；拍板与待回复两项并排时收紧一号。
    static let entrySize: CGFloat = 14
    static let tightEntrySize: CGFloat = 13
    static func entry(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    /// 窄处只剩一个数：比词更醒目。
    static let count = Font.system(size: entrySize, weight: .bold)
    /// 一句安静的话（没有要你管的、也没有在推进的）。
    static let word = entry(entrySize)
}
