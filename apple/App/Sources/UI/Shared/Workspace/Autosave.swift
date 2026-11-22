import Foundation

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
            self.timer = nil
            do { try await self.flush() } catch { self.onError(error) }
        }
    }

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
