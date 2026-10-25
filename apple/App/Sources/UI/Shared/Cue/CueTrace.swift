import CueStore
import SwiftUI

/// Cue 一轮的经过（Cue 页：你发起的一轮排在你的话之后，Cue 自己醒来的在跑那一轮挂在它那一行下面）：碰到的各处，一处一行（`CueActivity.touches`），
/// 行首动作的图标、动作词（与按钮同名）、那一处的名字；点一行去那一处（任务开任务气泡、会话进会话页，`Workspace.open`）。
/// 多于 `foldAfter` 处时只露前 `shownWhenFolded` 处，下面一行"还有 N 处"，点了就地展开。
/// 在跑时同一块原地往下长：正在做的那一步是末行（状态标、那一句带流光，同一套动词，`CueActivity.detail`）；在说话时没有这一行（话在对话里长出来），
/// 所以做完时末行早已收掉、碰到的那一处已是上面的一行，这一块原位停下、高度不跳。
/// 与醒来那几行同一种行（`CueNoteRow`），不铺底；左缘对着 Cue 气泡的左缘（Mac、iPad、iPhone 一样）。
struct CueTrace: View {
    let touches: [CueActivity.Touch]
    /// 在跑时此刻在做的（`CueLiveRound.doing`）
    let doing: CueLiveRound.Doing?
    @State private var unfolded = DebugHooks.preset.toolsOpen
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let foldAfter = 4
    static let shownWhenFolded = 3

    var body: some View {
        let folded = !unfolded && touches.count > Self.foldAfter
        let shown = folded ? Array(touches.prefix(Self.shownWhenFolded)) : touches
        VStack(alignment: .leading, spacing: 0) {
            // 一处只会往后加、动作原位换成更要紧的，下标就是它的身份
            ForEach(shown.indices, id: \.self) { index in line(shown[index]) }
            if folded {
                Button { unfolded = true } label: {
                    CueNoteRow { Image(.expand) } text: { Text("还有 \(touches.count - shown.count) 处") }
                }
                .buttonStyle(.row)
            }
            if let doing, !doing.shown.speaking {
                CueNoteRow { PiStateDot(shown: doing.shown, size: 6) } text: {
                    Text(doing.text).foregroundStyle(palette.ink2).shimmering()
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private func line(_ touch: CueActivity.Touch) -> some View {
        let row = CueNoteRow { Image(Self.icon(touch.kind)) } text: {
            Text("\(CueActivity.verb(touch.kind) ?? "") \(Text(touch.name).foregroundStyle(palette.ink2))")
        }
        if let target = touch.target {
            Button { workspace.open(target) } label: { row }.buttonStyle(.row)
        } else {
            row
        }
    }

    /// 动作的图标，与按钮同一个（查看是眼睛：Cue 看的是会话与任务，不是文件）。
    static func icon(_ kind: PiChatMessage.Tools.Kind) -> Icon {
        switch kind {
        case .read: .looked
        case .talk: .handOff
        case .add: .added
        case .start: .started
        case .stop: .endSession
        case .done: .complete
        case .leave: .yourTurn
        case .edit, .command, .search, .other, .said, .ask: .tool
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
