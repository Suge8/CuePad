import Foundation

/// 编辑中的正文自动保存：停手一小会儿后写入；离开页面、交给 Agent、进后台时 `flush`，返回即已落库。
/// 写不成的正文放回待写，`flush` 把错误抛给调用方（离开时据此不删"空白"的新灵感）；停手计时触发的那次没有调用方，错误交给 `onError`。
final class Autosave {
    private static let delay: Duration = .milliseconds(400)

    private let save: (String) async throws -> Void
    private let onError: (any Error) -> Void
    private var pending: String?
    private var timer: Task<Void, Never>?
    private var writing: Task<Void, any Error>?

    init(save: @escaping (String) async throws -> Void, onError: @escaping (any Error) -> Void) {
        self.save = save
        self.onError = onError
    }

    var unsaved: String? { pending }

    func changed(_ text: String) {
        pending = text
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self else { return }
            // 先放下自己：flush 会取消 timer，取消的若是正在跑的这一个，保存就在已取消的任务里执行
            self.timer = nil
            do { try await self.flush() } catch { self.onError(error) }
        }
    }

    /// 在途的那次也取消：能取消的写入会停，已经交出去的由调用方核对它写完时还算不算数。
    func discard() {
        pending = nil
        timer?.cancel()
        timer = nil
        writing?.cancel()
    }

    func flush() async throws {
        timer?.cancel()
        timer = nil
        while true {
            if let writing {
                try await writing.value
                continue
            }
            guard let text = pending else { return }
            pending = nil
            let save = save
            writing = Task {
                defer { writing = nil }
                do { try await save(text) } catch {
                    if pending == nil, !Task.isCancelled { pending = text }
                    throw error
                }
            }
        }
    }
}
