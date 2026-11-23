import CueStore
import SwiftUI

struct CueTrace: View {
    let touches: [CueActivity.Touch]
    @State private var unfolded = DebugHooks.preset.toolsOpen
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let rows = 3

    var body: some View {
        if touches.count > Self.rows {
            RisingFold(open: $unfolded, press: .row) {
                CueNoteRow { DisclosureChevron(open: unfolded) } text: {
                    if unfolded { Text("收起") } else { Text("还有 \(touches.count - Self.rows + 1) 处") }
                }
            } content: { unfolded in
                lines(unfolded ? touches : Array(touches.prefix(Self.rows - 1)))
            }
        } else {
            VStack(alignment: .leading, spacing: 0) { lines(touches) }
        }
    }

    private func lines(_ shown: [CueActivity.Touch]) -> some View {
        ForEach(shown.indices, id: \.self) { index in line(shown[index]) }
    }

    static func words(_ touch: CueActivity.Touch, name: Color) -> Text {
        Text("\(CueActivity.verb(touch.kind) ?? "") \(Text(touch.name).foregroundStyle(name))")
    }

    @ViewBuilder private func line(_ touch: CueActivity.Touch) -> some View {
        let row = CueNoteRow { Image(Self.icon(touch.kind)) } text: { Self.words(touch, name: palette.ink2) }
        if let target = touch.target {
            Button { workspace.open(target) } label: { row }.buttonStyle(.row)
        } else {
            row
        }
    }

    static func icon(_ kind: ChatMessage.Tools.Kind) -> Icon {
        switch kind {
        case .read: .looked
        case .talk: .handOff
        case .add: .added
        case .start: .started
        case .stop: .endSession
        case .done: .complete
        case .leave: SessionShown(status: .awaitsReply).icon
        case .schedule: .schedule
        case .edit: .write
        case .command, .search, .other, .said, .ask: .tool
        }
    }
}

extension CueActivity.Touch {
    var target: CueWakeHeader.Target? {
        if let task { return .task(task) }
        return session.map { .session($0, sessionID: nil) }
    }
}
