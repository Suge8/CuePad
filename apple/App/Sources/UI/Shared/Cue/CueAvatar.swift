import SwiftUI

/// Cue 的头像（全 App 只此一份）：吉祥物的表情（`CueMood`）外面一圈状态环，呼应它腰上那个环。
/// 环只说一件事：在想时一段弧在转（`LoopLayer`），等你时赭黄实环，空闲时一圈淡墨静止，睡着或起不来时整个头像变暗。
/// 三档尺寸：行内（任务行、会话标题旁，只露上半身：纸面、折角和眼睛）、侧栏与面板的一行、Cue 页页头。
/// `size` 是里面那张脸的直径，环画在它外面（外框大一圈）。减弱动态效果时在想是一段静止的弧。
struct CueAvatar: View {
    enum Size {
        case inline, row, head

        var face: CGFloat {
            switch self {
            case .inline: 16
            case .row: 28
            case .head: 56
            }
        }

        var line: CGFloat {
            switch self {
            case .inline: 1.5
            case .row: 2.5
            case .head: 4
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dimmed: Bool { presence.isAway }

    var body: some View {
        ZStack {
            ring
            face.frame(width: size.face, height: size.face)
        }
        .frame(width: size.box, height: size.box)
        .opacity(dimmed ? 0.5 : 1)
        .animation(Motion.quick, value: mood)
        .animation(Motion.quick, value: presence)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var face: some View {
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

    @ViewBuilder private var ring: some View {
        let inset = size.line / 2
        switch presence {
        case .thinking where !reduceMotion:
            LoopLayer(kind: .halo(lineWidth: size.line), color: palette.ink)
        case .thinking:
            Circle().trim(from: 0, to: 0.3).stroke(palette.ink, style: StrokeStyle(lineWidth: size.line, lineCap: .round)).padding(inset)
                .background { Circle().stroke(palette.ink.opacity(0.22), lineWidth: size.line).padding(inset) }
        default:
            Circle().stroke(ringTint, lineWidth: size.line).padding(inset)
        }
    }

    private var ringTint: Color {
        mood == .waiting && !dimmed ? palette.attention : palette.ink.opacity(0.22)
    }
}

/// 会话标题旁的跟进标记（iOS 会话页顶栏）：会话绑着的任务由 Cue 跟进时才有。Mac 的标题自己有绑着的任务（`SessionTaskLink`），直接放 `CueFollowMark`。
struct CueSessionMark: View {
    let sessionID: String
    @Environment(AppServices.self) private var services
    @State private var followed: Bool?

    var body: some View {
        // 读库前也要有一个真的视图：读库挂在它上面，什么都不排就永远不读
        HStack(spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
            if followed == true { CueFollowMark() }
        }
        .observing(services.store, id: sessionID, into: $followed) { [sessionID] in try CueWaiting.followed(sessionID, in: $0) }
    }
}

/// 由 Cue 跟进的标记（任务行、会话标题旁）：行内的小头像，读屏读"由 Cue 跟进"。
struct CueFollowMark: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let cue = workspace.cue
        CueAvatar(mood: cue.mood(), presence: cue.presence, size: .inline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("由 \(cue.name) 跟进")
            #if os(macOS)
            .help("由 \(cue.name) 跟进")
            #endif
    }
}
