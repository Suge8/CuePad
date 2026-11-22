import SwiftUI

final class SessionRailReveal {
    var active = false {
        didSet { if !active { busy = [] } }
    }
    var busy: Set<TaskBoard.Column> = []
    var visible: [TaskBoard.Column: Set<String>] = [:]
    var canReveal: Bool { active && busy.isEmpty }
    private var groups: [[String]] = []
    private var scrolls: [TaskBoard.Column: (String) -> Void] = [:]

    func update(_ groups: [[String]]) { self.groups = groups }

    func register(_ column: TaskBoard.Column, scroll: @escaping (String) -> Void) { scrolls[column] = scroll }

    func remove(_ column: TaskBoard.Column) {
        scrolls[column] = nil
        busy.remove(column)
        visible[column] = nil
    }

    func prepare(_ ends: [RelayEnd]) {
        guard canReveal else { return }
        let shown = visible.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for (column, group) in zip([TaskBoard.Column.waiting, .advancing], groups) {
            if let end = ends.first(where: { group.contains($0.session) }), !shown.contains(end.session) {
                scrolls[column]?(end.session)
            }
        }
    }
}
