import SwiftUI

/// 接力的排版屏障，不保存会话或导航状态。滚动身份来自当前行；新会话等读库结果挂载后再准备。
/// 用户触摸、拖动及惯性期间放弃滚入，不排队到松手后抢位置；已经完整可见的目标也不挪。
final class SessionRailReveal {
    var active = false {
        didSet { if !active { busy = []; finish() } }
    }
    var busy: Set<TaskBoard.Column> = [] {
        didSet { if !busy.isEmpty { finish() } }
    }
    var visible: [TaskBoard.Column: Set<String>] = [:]
    private var groups: [[String]] = []
    private var scrolls: [TaskBoard.Column: (String) -> Void] = [:]
    private var pending: Request?

    private struct Request {
        let id: UUID
        let ends: [RelayEnd]
        let continuation: CheckedContinuation<Void, Never>
    }

    func update(_ groups: [[String]]) {
        self.groups = groups
        resolve()
    }

    func register(_ column: TaskBoard.Column, scroll: @escaping (String) -> Void) {
        scrolls[column] = scroll
        resolve()
    }

    func remove(_ column: TaskBoard.Column) {
        scrolls[column] = nil
        busy.remove(column)
        visible[column] = nil
    }

    func prepare(_ ends: [RelayEnd]) async {
        guard active, busy.isEmpty else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finish()
                pending = Request(id: id, ends: ends, continuation: continuation)
                resolve()
            }
        } onCancel: {
            Task { @MainActor in
                if self.pending?.id == id { self.finish() }
            }
        }
    }

    private func resolve() {
        guard let pending else { return }
        let ids = Set(groups.joined())
        // start 的认领与会话条是不同的读库订阅；不把较早到的飞行事件误当成「没有落点」。
        guard !pending.ends.contains(where: { $0.opens && !ids.contains($0.session) }) else { return }
        let shown = visible.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for (column, group) in zip([TaskBoard.Column.waiting, .advancing], groups) {
            if let end = pending.ends.first(where: { group.contains($0.session) }), !shown.contains(end.session) {
                guard let scroll = scrolls[column] else { return }
                scroll(end.session)
            }
        }
        finish()
    }

    private func finish() {
        let request = pending
        pending = nil
        request?.continuation.resume()
    }
}
