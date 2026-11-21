import CueStore

nonisolated enum SessionPlace {
    static func name(project: Project?, folder: String?, besides title: String? = nil) -> String? {
        guard let place = project?.shownName ?? folder else { return nil }
        return title?.lowercased().hasPrefix(place.lowercased()) == true ? nil : place
    }

    static func name(of state: SessionState, project: Project?) -> String? {
        name(project: project, folder: state.folder, besides: state.title)
    }

    static func menuTitle(of state: SessionState, project: Project?) -> String? {
        name(of: state, project: project).map { String(localized: "在 \($0)") }
    }
}
