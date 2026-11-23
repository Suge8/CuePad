#if os(macOS)
import SwiftUI

@Observable
final class MacPages {

    private(set) var kept: [Route] = []

    private(set) var leaving: Route?

    @ObservationIgnored private var current: Route?
    @ObservationIgnored private var lastSeen: [Route: Int] = [:]
    @ObservationIgnored private var visits = 0
    @ObservationIgnored private var trimTask: Task<Void, Never>?
    static let keptPages = 4

    func visit(from left: Route?, to page: Route?) {
        current = page
        if let left { keep(left) }
        if let page { keep(page) }
        guard let left, left != page else { return }
        leaving = left
        Task { [weak self] in
            await NextFrame.wait()
            await NextFrame.wait()
            if self?.leaving == left { self?.leaving = nil }
        }
    }

    private func keep(_ page: Route) {
        visits += 1
        lastSeen[page] = visits
        guard !kept.contains(page) else { return }
        kept.append(page)
        if kept.count > Self.keptPages + 2 { trim() } else { scheduleTrim() }
    }

    func premount(_ page: Route) {
        if !kept.contains(page) { kept.append(page) }
    }

    func isPremounted(_ page: Route) -> Bool { lastSeen[page] == nil }

    func forget(projectsNotIn ids: Set<UUID>) {
        let gone = kept.filter { if case .project(let id) = $0 { !ids.contains(id) } else { false } }
        if !gone.isEmpty { kept.removeAll { gone.contains($0) } }
    }

    private func scheduleTrim() {
        trimTask?.cancel()
        trimTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.trim()
        }
    }

    private func trim() {
        let stale = kept.filter { $0 != current }.sorted { lastSeen[$0, default: 0] < lastSeen[$1, default: 0] }.prefix(max(0, kept.count - Self.keptPages))
        if !stale.isEmpty { kept.removeAll { stale.contains($0) } }
    }
}
#endif
