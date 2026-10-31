import CueStore
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct DraggedColumn: Codable, Transferable {
    let windowID: UUID
    let recordID: UUID
    let sessionID: String?
    static let type = UTType(exportedAs: "\(AppIdentity.id).column", conformingTo: .data)
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: type) }
}

extension EnvironmentValues {
    @Entry var wideWindowID: UUID?
}

#if os(iOS)
struct WideDrop: ViewModifier {
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.wideWindowID) private var windowID
    @State private var drop = WideDropState()

    func body(content: Content) -> some View {
        content
            .overlay { WideDropFeedback(state: drop) }
            .onDrop(of: [DraggedColumn.type.identifier, UTType.cuepadSession.identifier], isTargeted: Bindable(drop).targeted) { providers in
                guard let provider = providers.first else { return false }
                if provider.hasItemConformingToTypeIdentifier(DraggedColumn.type.identifier) {
                    load(DraggedColumn.self, type: DraggedColumn.type, from: provider) {
                        workspace.dropSession(SessionRoute(id: $0.recordID, sessionID: $0.sessionID), in: column, movingWithinWindow: $0.windowID == windowID)
                    }
                } else {
                    load(DraggedSession.self, type: .cuepadSession, from: provider) {
                        workspace.openSession(PiSessionState.recordID(sessionID: $0.sessionID), sessionID: $0.sessionID, in: column)
                    }
                }
                return true
            }
    }

    private func load<Value: Decodable & Sendable>(_ value: Value.Type, type: UTType, from provider: NSItemProvider, apply: @escaping @MainActor (Value) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            let result = Result { () throws -> Value in
                if let error { throw error }
                return try JSONDecoder().decode(value, from: data ?? Data())
            }
            Task { @MainActor in
                switch result {
                case .success(let value): apply(value)
                case .failure(let error): workspace.fail(error)
                }
            }
        }
    }
}

#endif

struct WideSessionTitle: View {
    let title: String
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.wideWindowID) private var windowID

    var body: some View {
        HStack {
            if let windowID, let session = workspace.session(in: column) {
                Text(verbatim: title).font(.headline).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .draggable(DraggedColumn(windowID: windowID, recordID: session.id, sessionID: session.sessionID))
            }
            Button("关闭", icon: .close) { workspace.closeColumn(column) }
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 16).frame(height: 44)
    }
}

@Observable
final class WideDropState {
    var targeted = false
}

struct WideDropFeedback: View {
    let state: WideDropState
    @Environment(\.palette) private var palette

    var body: some View {
        if state.targeted {
            palette.selection.overlay { Text("放在这里").font(.title2) }.allowsHitTesting(false)
        }
    }
}
