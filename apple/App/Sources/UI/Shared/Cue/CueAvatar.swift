import SwiftUI

/// Cue 的头像（全 App 只此一份）：吉祥物的表情（`CueMood`）外面一圈状态环，呼应它腰上那个环。
/// 颜色与会话状态标同一套（`PiShown.tint`）：在做事（想、用工具）时环是靛青、一段弧在转（`LoopLayer` 的 `orbit`），里面的它上下跳（`float`）；
/// 话在路上时靛青实环；等你时赭黄实环；空闲时一圈淡墨静止；睡着或起不来时整个头像变暗。
/// 三档尺寸：行内（任务行、会话标题旁，只露上半身：纸面、折角和眼睛，不跳）、侧栏与 Mac 页头的一行、手机 Cue 页头（`header`）。
/// `size` 是里面那张脸的直径，环画在它外面（外框大一圈）。减弱动态效果时在做事是一段静止的弧，它不跳。
struct CueAvatar: View {
    enum Size {
        case inline, row, header

        var face: CGFloat {
            switch self {
            case .inline: 16
            case .row: 28
            case .header: 36
            }
        }

        var line: CGFloat {
            switch self {
            case .inline: 1.5
            case .row: 2.5
            case .header: 3
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
    private var working: Bool { if case .working = presence { true } else { false } }

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
        } else if working, !reduceMotion, let bitmap = Self.bitmap(mood, side: size.face) {
            LoopLayer(kind: .float(bitmap, lift: size.face * Self.lift), color: .clear).padding(size.face * 0.04)
        } else {
            image.padding(size.face * 0.04)
        }
    }

    @ViewBuilder private var ring: some View {
        let inset = size.line / 2
        if working, !reduceMotion {
            LoopLayer(kind: .orbit(lineWidth: size.line), color: palette.signature)
        } else if working {
            Circle().trim(from: 0, to: 0.3).stroke(palette.signature, style: StrokeStyle(lineWidth: size.line, lineCap: .round)).padding(inset)
                .background { Circle().stroke(palette.selection, lineWidth: size.line).padding(inset) }
        } else {
            Circle().stroke(ringTint, lineWidth: size.line).padding(inset)
        }
    }

    private var ringTint: Color {
        if let shown = presence.shown { return shown.tint(palette) }
        return mood == .waiting && !dimmed ? palette.waiting : palette.track
    }

    /// 跳的幅度：脸的直径的这么多（28pt 的脸约 3.6pt）。
    private static let lift: CGFloat = 0.13

    /// 交给 Core Animation 的那张图（按 3 倍取，视网膜屏上不糊）。
    private static func bitmap(_ mood: CueMood, side: CGFloat) -> CGImage? {
        #if os(macOS)
        var rect = CGRect(x: 0, y: 0, width: side * 3, height: side * 3)
        return NSImage(named: mood.asset)?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        UIImage(named: mood.asset)?.cgImage
        #endif
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
