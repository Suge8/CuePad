#if os(iOS)
import SwiftUI

/// 底部那一排换形里每样东西多浓、点不点得到，全是 `PagerMotion.places` 的函数（1 是两格，0 是"⋯"加输入框）；拖动跟手、点按与松手的弹簧、
/// 减弱动态效果时直接到位，都只是 `places` 走得快慢不同，没有另外的交接时机。
/// 分两段，前后不相叠：先是两格（系统标签栏，不能变形）原地淡出，这一段别的都不动；淡完了才是后一段，Cue 钮长成输入框那么宽、那么高，
/// 同时"⋯"按原尺寸在左边淡入。底边那一格在后一段里交叉：玻璃连续，字不相叠。输入框（在 Cue 页里，随页滑）在前两成半连玻璃带字淡完，
/// Cue 钮的玻璃（不随页滑）在前三成淡入，它的字与头像等输入框淡完才起。
/// 被否决的：两格与 Cue 钮同时变（Cue 钮压在半透明的标签栏上，中途冒出半宽的空玻璃再缩成"⋯"）；按"停稳了没有"交接（交给输入框后等它画上屏一帧再藏 Cue 钮，
/// 收回时拍下输入框盖住）——几样状态互相触发，到 Cue 页时空玻璃闪两三帧、两行草稿时玻璃只一行高。
enum DockHandoff {
    /// 两格（系统标签栏）在这一段淡入淡出。
    static let tabs: ClosedRange<CGFloat> = 0.6...1
    /// Cue 钮从输入框的样子长成两格旁的宽度、高度：两格淡完才动。
    static let grow: ClosedRange<CGFloat> = 0...0.6
    /// 输入框（玻璃与字一起）在这一段淡出。
    static let composer: ClosedRange<CGFloat> = 0...0.25
    /// Cue 钮的玻璃在这一段淡入，与输入框的玻璃交叉。
    static let cueGlass: ClosedRange<CGFloat> = 0...0.3
    /// Cue 钮的字与头像：输入框淡完才起。
    static let cue: ClosedRange<CGFloat> = 0.3...0.6
    /// "⋯"在这一段淡出：与 Cue 钮变形同时，Cue 钮长到两格旁的宽度之前它已淡完。
    static let more: ClosedRange<CGFloat> = 0...0.4

    /// `places` 走过 `range` 时从 0 到 1。
    static func ramp(_ places: CGFloat, _ range: ClosedRange<CGFloat>) -> Double {
        Double(min(max((places - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1))
    }
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
        let owns = places < DockHandoff.composer.upperBound / 2
        content.opacity(1 - DockHandoff.ramp(places, DockHandoff.composer)).allowsHitTesting(owns).accessibilityHidden(!owns)
    }
}

extension EnvironmentValues {
    /// 根上那一条（`PagerMotion`）；宽屏没有底部那一排，为 nil。
    @Entry var dockMotion: PagerMotion?
}
#endif
