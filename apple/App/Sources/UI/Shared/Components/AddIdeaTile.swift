import SwiftUI

struct AddIdeaTile: View {
    enum Mood: String {
        case idea = "mascot-welcome", waiting = "mascot-cue-waiting", done = "mascot-cue-done"
    }

    var mood = Mood.idea
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    @ScaledMetric(relativeTo: .body) private var height = NoteTile.height
    private static let mascot: CGFloat = 56
    private static let hop: CGFloat = 4
    private static let dash = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 6])

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card)
        Button(action: action) {
            VStack(spacing: Spacing.item) {
                Image(decorative: mood.rawValue).resizable().scaledToFit()
                    .frame(width: Self.mascot, height: Self.mascot)
                    .id(mood).transition(Motion.pop(reduceMotion: reduceMotion))
                    .offset(y: hovering && !reduceMotion ? -Self.hop : 0)
                    .readerHidden(true)
                Text("添加灵感").font(Typography.bodyStrong).foregroundStyle(palette.ink2)
            }
            .padding(Spacing.block)
            .frame(maxWidth: .infinity).frame(height: height)
            .background { if hovering { shape.fill(palette.fill).transition(.opacity) } }
            .overlay { shape.strokeBorder(palette.track, style: Self.dash) }
            .contentShape(shape)
        }
        .buttonStyle(PressStyle(.card))
        .onHover { hovering = $0 }
        #if os(macOS)
        .presetHover($hovering)
        .help("添加灵感（⌘N）")
        #endif
        .animation(Motion.nudge, value: hovering)
        .animation(Motion.nudge, value: mood)
    }
}

enum NoteTile {
    #if os(macOS)
    static let height: CGFloat = 156
    static let thumbnail: CGFloat = 84
    #else
    static let height: CGFloat = 164
    static let thumbnail: CGFloat = 84
    #endif
    static let titleLines = 2
}
