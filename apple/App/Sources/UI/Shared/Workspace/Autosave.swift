import Foundation

/// 编辑中的正文自动保存：停手一小会儿后写入，离开页面时立即写入未保存的部分。
@MainActor
final class Autosave {
    private static let delay: Duration = .milliseconds(400)

    private let save: (String) async throws -> Void
    private let onError: (any Error) -> Void
    private var pending: String?
    private var timer: Task<Void, Never>?

    init(save: @escaping (String) async throws -> Void, onError: @escaping (any Error) -> Void) {
        self.save = save
        self.onError = onError
    }

    func changed(_ text: String) {
        pending = text
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        guard let text = pending else { return }
        pending = nil
        timer?.cancel()
        do { try await save(text) } catch { onError(error) }
    }
}
