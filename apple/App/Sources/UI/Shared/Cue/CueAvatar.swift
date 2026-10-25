import SwiftUI

/// Cue 的头像（全 App 只此一份）：吉祥物的表情（`CueMood`）托在一块淡底的圆上，没有环（样子同扩展里的头像，`CueFaceLayer`）：
/// Cue 在一轮里或话在路上时右下一颗靛青的点，不在时整个变淡；脸一直不动，在做什么由点与表情说。
/// 表情、在不在、在不在动都读 Cue 此刻（`CueNow`），同名牌、侧栏、小组件与灵动岛一份。
/// 四档尺寸：行内（任务行、会话标题旁，只露上半身：纸面、折角和眼睛）、侧栏与 Mac 页头的一行、iPhone 底部那一排的 Cue 钮与 Mac 侧栏名片（`header`）、
/// 手机与 iPad 的名片（`card`；名牌收着时缩到 `CueHeader.face`，长成名片时原样）。`size` 是那块圆的直径。
/// 被叫醒、做完时脸软糖地弹一下，在压得最扁时换表情（`Jelly`，同 Cue 的标签图标）。
struct CueAvatar: View {
    nonisolated enum Size {
        case inline, row, header, card

        var side: CGFloat {
            switch self {
            case .inline: 16
            case .row: 32
            case .header: 48
            case .card: 64
            }
        }
    }

    let mood: CueMood
    var busy = false
    var away = false
    var size = Size.row
    @Environment(\.palette) private var palette

    /// 按 Cue 此刻画；`mood` 给了时换掉它的表情（你正在写时的"在听"，`CueWatch.mood(composing:)`）。
    init(_ now: CueNow, mood: CueMood? = nil, size: Size) {
        self.init(mood: mood ?? now.mood, busy: now.isBusy, away: now.isAway, size: size)
    }

    init(mood: CueMood, busy: Bool = false, away: Bool = false, size: Size) {
        (self.mood, self.busy, self.away, self.size) = (mood, busy, away, size)
    }

    var body: some View {
        Group {
            if size == .inline {
                face(mood)
            } else {
                // 脸当场换（换表情在 `Jelly` 里压扁时换）：交叉淡的话两张姿势不同的脸会叠出重影
                Jelly(value: mood, move: JellyMove.cue) { mood, _ in face(mood).transition(.identity) }
                    .padding(size.side * 0.06)
                    .cueFace(size: size.side, busy: busy, away: away)
            }
        }
        .animation(HandOff.quick, value: mood)
        .animation(HandOff.quick, value: busy)
        .animation(HandOff.quick, value: away)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func face(_ mood: CueMood) -> some View {
        let image = Image(mood.asset).resizable().scaledToFit()
        if size == .inline {
            // 只露上半身：脸放大到比圆大，顶边对齐，圆裁掉下半截
            image.frame(width: size.side * 1.45).offset(y: size.side * 0.08)
                .frame(width: size.side, height: size.side, alignment: .top)
                .background(palette.paper)
                .clipShape(.circle)
        } else {
            image
        }
    }
}

/// 会话里 Cue 说的话上面那一行：小头像与名字（`UserBubble.fromCue`）。
struct CueByline: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 5) {
            CueAvatar(mood: .listening, size: .inline)
            Text(cue.name).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cue.name) 说")
    }
}
