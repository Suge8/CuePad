#if os(iOS)
import SwiftUI

/// 底部那一排换形里每样东西多浓、点不点得到，全是 `PagerMotion.places` 的函数（1 是三格，0 是"⋯"加输入框）；拖动跟手、点按与松手的弹簧、
/// 减弱动态效果时直接到位，都只是 `places` 走得快慢不同，没有另外的交接时机。
/// 底边那一格在换形里交叉：输入框（在 Cue 页里，随页滑）在前四成淡出，Cue 钮（不随页滑）同一段淡入、从输入框的样子长成两格宽，
/// 再往后它的字与头像、左边的三格才出来，"⋯"先淡完。两块玻璃各有内容的那一段相叠，手停在半路也不是两块空玻璃。
/// 被否决的：按"停稳了没有"交接（交给输入框后等它画上屏一帧再藏 Cue 钮，收回时拍下输入框盖住）——几样状态互相触发，
/// 到 Cue 页时空玻璃闪两三帧、两行草稿时玻璃只一行高，点"⋯"时字一帧没了，快照的加号浮在缩小的胶囊外。
enum DockHandoff {
    /// `places` 走过 `from…to` 时从 0 到 1。
    static func ramp(_ places: CGFloat, from: CGFloat, to: CGFloat) -> Double { Double(min(max((places - from) / (to - from), 0), 1)) }

    /// 输入框在这一段淡出、Cue 钮的玻璃在这一段淡入。
    static let swap: ClosedRange<CGFloat> = 0...0.4
    static let cue: ClosedRange<CGFloat> = 0.25...0.75
    static let more: ClosedRange<CGFloat> = 0...0.45
    static let cells: ClosedRange<CGFloat> = 0.35...0.85

    static func ramp(_ places: CGFloat, _ range: ClosedRange<CGFloat>) -> Double { ramp(places, from: range.lowerBound, to: range.upperBound) }
}

extension View {
    /// Cue 页的输入框：在换形里与 Cue 钮交叉（`DockHandoff`）；宽屏没有底部那一排，一直是它的。
    func dockedComposer(_ motion: PagerMotion?) -> some View {
        modifier(DockedComposer(motion: motion))
    }
}

private struct DockedComposer: ViewModifier {
    let motion: PagerMotion?

    func body(content: Content) -> some View { content.modifier(ComposerFade(places: motion?.places ?? 0)) }
}

/// 逐帧按 `places` 算（`Animatable`）：弹簧插的是进度，不是首尾两个不透明度。
private struct ComposerFade: ViewModifier, Animatable {
    var places: CGFloat

    var animatableData: CGFloat {
        get { places }
        set { places = newValue }
    }

    func body(content: Content) -> some View {
        let owns = places < DockHandoff.swap.upperBound / 2
        content.opacity(1 - DockHandoff.ramp(places, DockHandoff.swap)).allowsHitTesting(owns).accessibilityHidden(!owns)
    }
}

extension EnvironmentValues {
    /// 根上那一条（`PagerMotion`）；宽屏没有底部那一排，为 nil。
    @Entry var dockMotion: PagerMotion?
}
#endif
