import CueStore
import SwiftUI

/// 你发起的一轮的经过（Cue 页，排在你的话之后；Cue 自己醒来的一轮只有醒来那一行，`CueNoteLog`）：碰到的各处，一处一行（`CueActivity.touches`），
/// 行首动作的图标、动作词（`CueActivity.verb`）、那一处的名字；点一行去那一处（任务开任务气泡、会话进会话页，`Workspace.open`）。
/// 这是记录，只读同步来的那一行清单（`CueMessage.tools`）：一步做完才落进清单，碰到新的一处接在末尾，同一处只把动作原位换成更要紧的，
/// 出现了就一直在、顺序不变，在跑时、做完后、各台设备、重开前后一样。此刻在做的那一步不进这里，只写在对话末尾常驻的那一行（`CueEnding`）：
/// 它一出一收、换字都不改这一块的高，对话不跳。
/// 至多 `rows` 行（不算点开之后）：放不下时露前几处，末行"还有 N 处"（点了就地展开）。
/// 与醒来那几行同一种行（`CueNoteRow`），不铺底；左缘对着 Cue 气泡的左缘（Mac、iPad、iPhone 一样）。
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

    /// 动词淡墨、名字次要墨（`name`）："发给 登录回调超时"。自己醒来那一行的去处落在别处时也这样写（`CueNoteLog`）。
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

    /// 动作的图标，与按钮同一个（查看是眼睛：Cue 看的是会话与任务，不是文件）；留给你画待回复的图形，只取状态那一处（`PiShown.icon`），不读会话此刻的状态。
    static func icon(_ kind: PiChatMessage.Tools.Kind) -> Icon {
        switch kind {
        case .read: .looked
        case .talk: .handOff
        case .add: .added
        case .start: .started
        case .stop: .endSession
        case .done: .complete
        case .leave: PiShown(status: .awaitsReply).icon
        case .schedule: .schedule
        case .edit: .write
        case .command, .search, .other, .said, .ask: .tool
        }
    }
}

extension CueActivity.Touch {
    /// 点了去哪：认出来的任务与会话；认不出的只写名字、不能点。
    var target: CueWakeHeader.Target? {
        if let task { return .task(task) }
        return session.map { .session($0, sessionID: nil) }
    }
}
