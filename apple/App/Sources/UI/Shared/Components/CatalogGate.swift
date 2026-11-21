import SwiftUI

struct CatalogGate<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let failure = workspace.catalogFailure {
            UnreadableLibraryView(failure: LibraryFailure(reason: failure, location: workspace.services.location)) {
                workspace.retryCatalog()
            }
        } else {
            content
        }
    }
}
