#if os(iOS) && DEBUG
import SwiftUI

extension DebugScene {
    static func prepare(_ workspace: Workspace, _ navigation: Navigation) async {
        let project = await prepareLibrary(workspace)
        let split = navigation.layout == .split
        func open(_ route: Navigation.Route) {
            if split { navigation.select(route) } else { navigation.projectsPath = [route] }
        }
        switch scene {
        case "project", "older": if let project { open(.project(project)) }
        case "today": open(.today)
        case "trash": open(.trash)
        case "settings": open(.settings)
        case "editor":
            if let project { open(.project(project)) }
            if let card = await card(in: project, store: workspace.services.store) { navigation.push(.card(card)) }
        case "tasks":
            if let project { open(.project(project)) }
            if split { navigation.showsTasks = true } else { navigation.tab = .tasks }
        case "search":
            if split { navigation.select(.search) } else { navigation.tab = .search }
        case "capture":
            if let project { open(.project(project)) }
            navigation.startCapture()
        default:
            if let project, split { open(.project(project)) }
        }
    }
}
#endif
