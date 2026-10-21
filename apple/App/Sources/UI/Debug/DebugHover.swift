#if DEBUG && os(macOS)
import Foundation

extension DebugScene {
    /// `-CuePadHover` 给的几点（窗口里，左上为原点，同 `-CuePadClick`）：盖住它们的按钮、行与卡画成指针停着的样子（`presetHover`）。
    static var hoverPoints: [CGPoint] {
        (defaults.string(forKey: "CuePadHover") ?? "").split(separator: ";").compactMap { spot in
            let parts = spot.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
        }
    }
}
#endif
