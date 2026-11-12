import SwiftUI

/// 画哪一拍由调用方给（App 里都是 `CueWatch.beat`），这里不另记；放哪条帧序列只在 `CueSprite.of`。
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
    /// 头像后面垫的淡圆底；放在自己有底的格里时不要（会话条最上那一格）。
    let plate: Bool
    @Environment(\.palette) private var palette
    @LoopsPlay private var loops

    init(_ beat: CueBeat, size: Size, plate: Bool = true) {
        (self.beat, self.size, self.plate) = (beat, size, plate)
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
                .background(plate ? palette.hair : .clear, in: .circle)
            }
        }
        .readerHidden(true)
    }

    @ViewBuilder private func face(_ beat: CueBeat, intro: Bool) -> some View {
        if loops, let sheet = CueAtlas.shared.sheet {
            LoopLayer(sprite: CueSprite.of(beat, compact: size.compact), sheet: sheet, intro: intro)
        } else {
            Image(beat.still).resizable().scaledToFit()
        }
    }

    private var inline: some View {
        Image(beat.still).resizable().scaledToFit()
            .frame(width: size.side * 1.45).offset(y: size.side * 0.08)
            .frame(width: size.side, height: size.side, alignment: .top)
            .background(palette.paper)
            .clipShape(.circle)
            .cueMarks(size: size.side, beat: beat)
    }
}

struct CueByline: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: Spacing.glyph) {
            CueAvatar(.resting, size: .inline)
            Text(cue.name).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cue.name) 说")
    }
}
