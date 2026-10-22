import SwiftUI

/// Cue 的头像（全 App 只此一份）：吉祥物的表情（`CueMood`）外面一圈状态环，呼应它腰上那个环。
/// 环的颜色与会话状态标同一套（`PiShown.tint`）：在做事（想、用工具）时靛青，环上一颗彗星匀速绕着走（`LoopLayer` 的 `comet`）；
/// 话在路上靛青实环；等你赭黄实环；刚报了一件做完石绿实环；静着一圈淡墨；睡着或起不来时整个头像变暗。脸一直不动：在做什么只由环说。
/// 开始与停下时彗星与静止的环交叉淡入淡出（`handoff`）；减弱动态效果或省电模式（`LowPowerMode`）时在做事是一段静止的弧。
/// 页面消失或 App 不活跃时直接摘掉彗星层，回到前台再起。前后台与省电的观察只在工作环里，静止时是一层描边，不挂动效容器。
/// 三档尺寸：行内（任务行、会话标题旁，只露上半身：纸面、折角和眼睛）、侧栏与 Mac 页头的一行、手机 Cue 页头（`header`）。
/// `size` 是里面那张脸的直径，环画在它外面（外框大一圈）。
/// 被叫醒、做完时脸软糖地弹一下，在压得最扁时换表情（`Jelly`，同 Cue 的标签图标）。
struct CueAvatar: View {
    enum Size {
        case inline, row, header

        var face: CGFloat {
            switch self {
            case .inline: 16
            case .row: 28
            case .header: 42
            }
        }

        var line: CGFloat {
            switch self {
            case .inline: 1.5
            case .row: 2.5
            case .header: 3.5
            }
        }

        var gap: CGFloat { line * 0.6 }
        /// 外框边长（脸加两侧的缝与环）。
        var box: CGFloat { face + 2 * (gap + line) }
    }

    let mood: CueMood
    var presence = CuePresence.idle
    var size = Size.row
    @Environment(\.palette) private var palette
    @State private var visible = false

    private var dimmed: Bool { presence.isAway }
    private var working: Bool { if case .working = presence { true } else { false } }

    /// 彗星与静止的环换手：只淡入淡出（彗星淡出时照转），比颜色反馈（`HandOff.quick`）长一点，看得出是收住、不是消失。
    private static let handoff = Animation.easeInOut(duration: 0.3)

    var body: some View {
        ZStack {
            ring
            // 脸当场换（换表情在 `Jelly` 里压扁时换）：交叉淡的话两张姿势不同的脸会叠出重影
            Jelly(value: mood, move: JellyMove.cue) { mood, _ in face(mood).transition(.identity) }.frame(width: size.face, height: size.face)
        }
        .frame(width: size.box, height: size.box)
        .opacity(dimmed ? 0.5 : 1)
        .animation(HandOff.quick, value: mood)
        .animation(HandOff.quick, value: presence)
        .accessibilityHidden(true)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    @ViewBuilder private func face(_ mood: CueMood) -> some View {
        let image = Image(mood.asset).resizable().scaledToFit()
        if size == .inline {
            // 只露上半身：脸放大到比圆大，顶边对齐，圆裁掉下半截
            image.frame(width: size.face * 1.45).offset(y: size.face * 0.08)
                .frame(width: size.face, height: size.face, alignment: .top)
                .background(palette.paper)
                .clipShape(.circle)
        } else {
            image.padding(size.face * 0.04)
        }
    }

    private var ring: some View {
        Group {
            if working {
                WorkingRing(lineWidth: size.line, visible: visible).transition(.opacity)
            } else {
                Circle().stroke(ringTint, lineWidth: size.line).padding(size.line / 2).transition(.opacity)
            }
        }
        .animation(Self.handoff, value: working)
    }

    private struct WorkingRing: View {
        let lineWidth: CGFloat
        let visible: Bool
        @Environment(\.palette) private var palette
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.scenePhase) private var scenePhase

        private var spinning: Bool { visible && scenePhase == .active && !reduceMotion && !LowPowerMode.shared.isOn }

        var body: some View {
            Group {
                if spinning {
                    LoopLayer(kind: .comet(lineWidth: lineWidth), color: palette.signature).transition(.opacity)
                } else {
                    Circle().trim(from: 0, to: 0.3).stroke(palette.signature, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)).padding(lineWidth / 2)
                        .background { Circle().stroke(palette.selection, lineWidth: lineWidth).padding(lineWidth / 2) }
                        .transition(.opacity)
                }
            }
            .animation(CueAvatar.handoff, value: spinning)
            .transaction { if !visible || scenePhase != .active { $0.animation = nil } }
        }
    }

    /// 话在路上同会话的状态色，其余跟着表情（`CueMood.ring`，扩展里的头像同一条）。
    private var ringTint: Color { presence.shown?.tint(palette) ?? mood.ring(palette) }
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
