import Foundation

/// 刚从刻度滑条跳到的那条你的话，短暂描一圈（`chatHighlight`）。
@Observable final class ChatHighlight {
    private(set) var id: UUID?
    private var fading: Task<Void, Never>?

    func flash(_ id: UUID, for duration: Duration = .seconds(1.2)) {
        self.id = id
        fading?.cancel()
        fading = Task { [weak self] in
            guard (try? await Task.sleep(for: duration)) != nil else { return }
            self?.id = nil
        }
    }
}
