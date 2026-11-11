import CueStore
import SwiftUI

/// 这是记录，只读同步来的那一行清单（`CueMessage.tools`）：一步做完才落进清单，同一处只把动作原位换成更要紧的，出现了就一直在、顺序不变，各台设备、重开前后一样。
/// 此刻在做的那一步不进这里，只写在对话末尾常驻的那一行（`CueEnding`）：它一出一收、换字都不改这一块的高，对话不跳。
struct CueTrace: View {
    let touches: [CueActivity.Touch]
    @State private var unfolded = DebugHooks.preset.toolsOpen
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let rows = 4

    var body: some View {
        let folded = !unfolded && touches.count > Self.rows
        let shown = folded ? Array(touches.prefix(Self.rows - 1)) : touches
        VStack(alignment: .leading, spacing: 0) {
            // 一处只会往后加、动作原位换成更要紧的，下标就是它的身份
            ForEach(shown.indices, id: \.self) { index in line(shown[index]) }
            if folded {
                Button { unfolded = true } label: {
                    CueNoteRow { Image(.expand) } text: { Text("还有 \(touches.count - shown.count) 处") }
                }
                .buttonStyle(.row)
            }
        }
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

    /// 查看是眼睛：Cue 看的是会话与任务，不是文件；留给你画待回复的图形，只取状态那一处（`SessionShown.icon`），不读会话此刻的状态。
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
