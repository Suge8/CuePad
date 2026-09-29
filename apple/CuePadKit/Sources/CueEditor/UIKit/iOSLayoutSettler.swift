#if canImport(UIKit)
import UIKit

/// TextKit 2 只布局视口，其余按估算高度算滚动范围，滚动时才逐步修正，滚动条会跳变。
/// 这里在主循环空闲时分片把整篇文档预先布局完，让文档总高度在用户滚动前收敛。
/// 每片只占几毫秒，输入和滚动的事件随时插队；文档重载、宽度或主题变化后重新开始。
@MainActor
final class LayoutSettler {
    private static let sliceBudget: Duration = .milliseconds(6)

    private weak var textView: CueTextView?
    private var generation = 0

    init(textView: CueTextView) { self.textView = textView }

    func restart() {
        generation += 1
        schedule(from: nil, generation: generation)
    }

    private func schedule(from location: (any NSTextLocation)?, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.generation else { return }
            self.runSlice(from: location, generation: generation)
        }
    }

    private func runSlice(from start: (any NSTextLocation)?, generation: Int) {
        guard let layout = textView?.textLayoutManager, let content = layout.textContentManager else { return }
        let deadline = ContinuousClock.now + Self.sliceBudget
        var next: (any NSTextLocation)?
        layout.enumerateTextLayoutFragments(from: start ?? content.documentRange.location, options: [.ensuresLayout]) { fragment in
            next = fragment.rangeInElement.endLocation
            return ContinuousClock.now < deadline
        }
        // 让文本视图按最新的用量重算总高度：单纯 ensureLayout 不会更新 contentSize，要走一次视口布局
        layout.textViewportLayoutController.layoutViewport()
        guard let next, next.compare(content.documentRange.endLocation) == .orderedAscending else { return }
        schedule(from: next, generation: generation)
    }
}
#endif
