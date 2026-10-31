import CueStore
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct DraggedColumn: Codable, Transferable {
    let leading: Bool
    static let type = UTType(exportedAs: "\(AppIdentity.id).column", conformingTo: .data)
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: type) }
}

struct WideDrop: ViewModifier {
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    palette.selection
                        .overlay { Text("放在这里").font(.title2) }
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [DraggedColumn.type.identifier, UTType.cuepadSession.identifier], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                if provider.hasItemConformingToTypeIdentifier(DraggedColumn.type.identifier) {
                    load(DraggedColumn.self, type: DraggedColumn.type, from: provider) {
                        workspace.moveSession(from: $0.leading ? .main : .side, to: column)
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

struct WideSessionTitle: View {
    let title: String
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack {
            Text(verbatim: title).font(.headline).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .draggable(DraggedColumn(leading: column == .main))
            Button("关闭", icon: .close) { workspace.closeColumn(column) }
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 16).frame(height: 44)
    }
}
