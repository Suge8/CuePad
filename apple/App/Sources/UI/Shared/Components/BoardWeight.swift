import SwiftUI

extension TaskBoard.Column {
    var light: Bool { self == .todo || self == .done }

    func paper(_ palette: Palette) -> Color? {
        switch self {
        case .waiting: palette.waitingPaper
        case .todo, .advancing, .done: nil
        }
    }

    func titleInk(_ palette: Palette) -> Color {
        switch self {
        case .todo: palette.ink2
        case .done: palette.ink3
        case .advancing, .waiting: palette.ink
        }
    }

    var titleWeight: Font.Weight? { light ? .regular : nil }

    func countInk(_ palette: Palette) -> Color {
        switch self {
        case .advancing: palette.signature
        case .waiting: palette.waiting
        case .todo, .done: palette.ink3
        }
    }

    var share: CGFloat { light ? 0.85 : 1.15 }
}
