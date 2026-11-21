import SwiftUI

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

        var compact: Bool { side <= Self.row.side }
    }

    let beat: CueBeat
    let size: Size
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

struct CueMark: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let name = workspace.cue.name
        CueAvatar(.resting, size: .inline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) 说")
            #if os(macOS)
            .help(name)
            #endif
    }
}
