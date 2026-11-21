#if os(iOS)
import SwiftUI

struct BubbleDrag: Equatable {
    nonisolated(unsafe) let bubble: AnyHashable
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ predicted: CGFloat) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.bubble == b.bubble }
}

extension EnvironmentValues {
    @Entry var bubbleDrag: BubbleDrag?
}
#endif
