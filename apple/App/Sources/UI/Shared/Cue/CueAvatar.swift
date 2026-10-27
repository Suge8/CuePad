import SwiftUI

/// Cue 的头像（全 App 只此一份）：吉祥物托在一块淡底的圆上，没有环；样子只读这一拍（`CueBeat`：静止图、点、变淡，同扩展里的头像 `CueNowFace`）。
/// 画哪一拍由调用方给（App 里都是 `CueWatch.beat`：飞向它的光——叫醒、发出——还在路上时停在起飞那一刻的那一拍，光落到右下那颗点上才换），这里不另记。
/// 小人自己会动：这一拍放哪条帧序列只在 `CueSprite.of`，由 `LoopLayer(sprite:sheet:intro:)` 从拼图（`CueAtlas`）里换帧；不放循环动效时（`LoopsPlay`：减弱动态效果、省电、
/// 页不在前台）与拼图解好之前画这一拍的静止图。32pt 及以下只放轮廓变了的帧（`compact`）。
/// 换拍子时脸软糖地动一下（`JellyMove.cue`），在压得最扁那一刻姿势、点、变淡一起换（都在 `Jelly` 画的那个值里）；做完的欢呼只在换进来的那一下放。
/// 四档尺寸：行内（16pt，只露上半身：纸面、折角和眼睛，不动；点与变淡照样有，在动、起不来、不在分得出）、侧栏与 Mac 页头的一行、
/// Mac 侧栏名片（`header`）、手机与 iPad 的名片（`card`；名牌收着时缩到 `CueHeader.face`，长成名片时原样）。`size` 是那块圆的直径。
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

        /// 只放轮廓变了的帧：眼睛只挪一两点的帧在这么小的头像上看不出来。
        var compact: Bool { side <= Self.row.side }
    }

    let beat: CueBeat
    let size: Size
    @Environment(\.palette) private var palette
    @LoopsPlay private var loops

    init(_ beat: CueBeat, size: Size) {
        (self.beat, self.size) = (beat, size)
    }

    var body: some View {
        let side = size.side
        Group {
            if size == .inline {
                inline
            } else {
                Jelly(value: beat, look: { $0.still }, move: JellyMove.cue) { beat, phase in
                    face(beat, intro: phase == .entering).padding(side * 0.06).frame(width: side, height: side).cueMarks(size: side, beat: beat)
                }
                .background(palette.hair, in: .circle)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func face(_ beat: CueBeat, intro: Bool) -> some View {
        if loops, let sheet = CueAtlas.shared.sheet {
            LoopLayer(sprite: CueSprite.of(beat, compact: size.compact), sheet: sheet, intro: intro)
        } else {
            Image(beat.still).resizable().scaledToFit()
        }
    }

    /// 只露上半身：脸放大到比圆大，顶边对齐，圆裁掉下半截；点与变淡照样挂在圆上。
    private var inline: some View {
        Image(beat.still).resizable().scaledToFit()
            .frame(width: size.side * 1.45).offset(y: size.side * 0.08)
            .frame(width: size.side, height: size.side, alignment: .top)
            .background(palette.paper)
            .clipShape(.circle)
            .cueMarks(size: size.side, beat: beat)
    }
}

/// 会话里 Cue 说的话上面那一行：小头像与名字（`UserBubble.fromCue`）。
struct CueByline: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 5) {
            CueAvatar(.resting, size: .inline)
            Text(cue.name).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cue.name) 说")
    }
}
