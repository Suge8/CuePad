import SwiftUI

/// 小组件与实时活动里的图标：扩展里没有 App 的资源目录与 `Icon`，生成器把这几个墨块符号另拷一份进小组件的 Symbols.xcassets
/// （design/tools/cue-symbols.py 的 `WIDGET_SYMBOLS`）。意思与 `Icon` 里同名的一样，App 里画的 Debug 舞台读到的是 App 资源里的同一个符号。
nonisolated enum WidgetIcon: String, Sendable {
    case waiting
    case done

    var image: Image { Image("cue.\(rawValue)") }
}
