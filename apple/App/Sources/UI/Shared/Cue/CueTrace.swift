import CueStore
import SwiftUI

/// Cue 一轮的经过（Cue 页：你发起的一轮排在你的话之后，Cue 自己醒来的在跑那一轮挂在它那一行下面）：碰到的各处，一处一行（`CueActivity.touches`），
/// 行首动作的图标、动作词（与按钮同名）、那一处的名字；点一行去那一处（任务开任务气泡、会话进会话页，`Workspace.open`）。
/// 在跑时同一块原地往下长：正在做的那一步（`CueState.step`）与做完的各步按同一条规矩并成一处一行（`CueActivity.merge`）——碰到已在上面的那一处，
/// 就是那一行在动、动作原位换成更要紧的；碰到新的一处，接在末尾。那一行整行流光，做完后落进清单的那一条并回同一行、写同一个动作，
/// 所以在跑时与做完后、各台设备、重开前后，同一轮的经过一样，不会先多出一行再收掉。没碰哪一处的一步（看板、记忆、在想）是末尾另一行，图标加那一句；
/// 在说话时没有这一行（话在对话里长出来）。
/// 任何时候至多 `rows` 行（不算点开之后）：放不下时露前几处，接一行"还有 N 处"（点了就地展开）；在动的那一处折在里面时补在它前面。
/// 与醒来那几行同一种行（`CueNoteRow`），不铺底；左缘对着 Cue 气泡的左缘（Mac、iPad、iPhone 一样）。
struct CueTrace: View {
    let touches: [CueActivity.Touch]
    /// 在跑时此刻在做的（`CueLiveRound.doing`）
    let doing: CueLiveRound.Doing?
    @State private var unfolded = DebugHooks.preset.toolsOpen
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let rows = 4

    var body: some View {
        let live = doing.flatMap { $0.speaking ? nil : $0 }
        var lines = touches
        let moving = live?.step.map { CueActivity.merge($0, into: &lines) }
        // 没碰哪一处的那一步另占末行
        let room = Self.rows - (live != nil && moving == nil ? 1 : 0)
        let folded = !unfolded && lines.count > room
        // 折起时"还有 N 处"占一行；在动的那一处折在里面时再让出一行给它
        let shown: [Int] = switch (folded, moving) {
        case (false, _): Array(lines.indices)
        case (true, let moving?) where moving >= room - 1: Array(0..<room - 2) + [moving]
        case (true, _): Array(0..<room - 1)
        }
        VStack(alignment: .leading, spacing: 0) {
            // 一处只会往后加、动作原位换成更要紧的，下标就是它的身份
            ForEach(shown, id: \.self) { index in line(lines[index], moving: index == moving) }
            if folded {
                Button { unfolded = true } label: {
                    CueNoteRow { Image(.expand) } text: { Text("还有 \(lines.count - shown.count) 处") }
                }
                .buttonStyle(.row)
            }
            if let live, moving == nil {
                CueNoteRow { Image(live.icon) } text: { Text(live.text) }
                    .shimmering()
                    .accessibilityLabel(live.text)
                    .transition(.opacity)
            }
        }
    }

    /// 动词淡墨、名字次要墨："发给 登录回调超时"。
    private func words(_ touch: CueActivity.Touch) -> Text {
        Text("\(CueActivity.verb(touch.kind) ?? "") \(Text(touch.name).foregroundStyle(palette.ink2))")
    }

    private func line(_ touch: CueActivity.Touch, moving: Bool) -> some View {
        let row = CueNoteRow { Image(Self.icon(touch.kind)) } text: { words(touch) }
        return Group {
            if let target = touch.target {
                Button { workspace.open(target) } label: { row }.buttonStyle(.row)
            } else {
                row
            }
        }
        .shimmering(moving)
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
