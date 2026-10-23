extension SidebarOutline.Entry {
    var route: Route {
        switch self {
        case .progress: .progress
        case .projects: .shelf
        case .archive: .archive
        case .trash: .trash
        case .settings: .settings
        }
    }
}
