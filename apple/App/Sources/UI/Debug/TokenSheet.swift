#if DEBUG
import SwiftUI

/// 样式总览（`-CuePadScene tokens`）：令牌各档直接从令牌类型取、不抄值。哪一档没列进来，`lint_tokens.py` 报。
struct TokenSheet: View {
    @Environment(\.palette) private var palette

    private static let swatch: CGFloat = 22
    private static let swatchCell: CGFloat = 132
    private static let corner: CGFloat = 44
    private static let longest: CGFloat = 160
    private static let columnWidth: CGFloat = 340

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.columnWidth), spacing: Spacing.part, alignment: .topLeading)], alignment: .leading, spacing: Spacing.part) {
                column {
                    group("Palette") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.swatchCell), alignment: .leading)], alignment: .leading, spacing: Spacing.tight) {
                            ForEach(Self.colors(palette), id: \.0) { name, color in
                                swatch(name, color)
                            }
                        }
                        HStack(spacing: Spacing.tight) {
                            ForEach(Palette.projectColors, id: \.stored) { color in
                                RoundedRectangle(cornerRadius: Radius.chip).fill(palette.project(color.stored)).frame(width: Self.swatch, height: Self.swatch)
                            }
                            label("projectColors")
                        }
                    }
                    group("Elevation") {
                        HStack(spacing: Spacing.block) {
                            ForEach(Elevation.allCases, id: \.self) { level in
                                label("\(level)").frame(width: Self.corner * 1.5, height: Self.corner)
                                    .background(palette.paper, in: .rect(cornerRadius: Radius.block)).elevation(level)
                            }
                        }
                    }
                    group("Motion") { label(Self.motions.joined(separator: "  ")) }
                }
                column { typography }
                column {
                    radii
                    spacing
                    glyphs
                }
            }
            .padding(Spacing.page)
        }
        .defaultScrollAnchor(DebugScene.args.layoutOpts.sheetEnd ? .bottom : .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.desk)
        .foregroundStyle(palette.ink)
    }

    private var radii: some View {
        group("Radius") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.corner), spacing: Spacing.item)], alignment: .leading, spacing: Spacing.item) {
                ForEach(Self.radii, id: \.0) { name, value in
                    VStack(spacing: Spacing.hair) {
                        RoundedRectangle(cornerRadius: value).fill(palette.fill).strokeBorder(palette.hair).frame(width: Self.corner, height: Self.corner)
                        label(name)
                    }
                }
                VStack(spacing: Spacing.hair) {
                    Radius.nested.fill(palette.track).padding(Spacing.tight)
                        .frame(width: Self.corner, height: Self.corner)
                        .background(palette.fill, in: .rect(cornerRadius: Radius.card)).containerShape(.rect(cornerRadius: Radius.card))
                    label("nested")
                }
            }
        }
    }

    private var spacing: some View {
        group("Spacing") {
            Grid(alignment: .leading, horizontalSpacing: Spacing.item, verticalSpacing: Spacing.tight) {
                ForEach(Self.spacings, id: \.0) { name, value in
                    GridRow {
                        label(name)
                        Text(value, format: .number).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
                        palette.signature.frame(width: min(value, Self.longest), height: Spacing.item)
                    }
                }
            }
        }
    }

    func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.part, content: content).frame(maxWidth: .infinity, alignment: .leading)
    }

    func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            Text(verbatim: title).font(Typography.sectionTitle)
            content()
        }
    }

    func label(_ name: String) -> some View {
        Text(verbatim: name).font(Typography.caption.monospaced()).foregroundStyle(palette.ink2).lineLimit(1)
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        HStack(spacing: Spacing.glyph) {
            RoundedRectangle(cornerRadius: Radius.chip).fill(color).strokeBorder(palette.hair).frame(width: Self.swatch, height: Self.swatch)
            label(name)
        }
    }

    private static func colors(_ palette: Palette) -> [(String, Color)] {
        [
            ("sidebar", palette.sidebar), ("desk", palette.desk), ("paper", palette.paper), ("paperLit", palette.paperLit),
            ("sheen", palette.sheen), ("bubble", palette.bubble), ("bubbleEdge", palette.bubbleEdge ?? .clear),
            ("glassTint", palette.glassTint), ("solidGlass", palette.solidGlass), ("inkWell", palette.inkWell),
            ("ink", palette.ink), ("ink2", palette.ink2), ("ink3", palette.ink3), ("hair", palette.hair), ("fill", palette.fill),
            ("track", palette.track), ("backdrop", palette.backdrop), ("shadow", palette.shadow), ("panelShadow", palette.panelShadow),
            ("onMedia", palette.onMedia), ("mediaScrim", palette.mediaScrim), ("mediaGround", palette.mediaGround),
            ("mediaEdge", palette.mediaEdge), ("mediaDim", palette.mediaDim),
            ("signature", palette.signature), ("signatureSoft", palette.signatureSoft), ("signatureFill", palette.signatureFill),
            ("selection", palette.selection), ("searchMatch", Palette.searchMatch), ("onFill", palette.onFill),
            ("waiting", palette.waiting), ("waitingFill", palette.waitingFill), ("failure", palette.failure),
            ("failureFill", palette.failureFill), ("failureTrack", palette.failureTrack), ("replied", palette.replied),
            ("repliedFill", palette.repliedFill), ("failureWash", palette.failureWash), ("repliedWash", palette.repliedWash),
            ("diffAdded", palette.diffAdded), ("diffRemoved", palette.diffRemoved),
            ("waitingPaper", palette.waitingPaper), ("neutralFill", palette.neutralFill),
            ("quietFill", palette.quietFill),
        ]
    }

    private static let radii: [(String, CGFloat)] = [
        ("chip", Radius.chip), ("block", Radius.block), ("card", Radius.card), ("sheet", Radius.sheet),
        ("field", Radius.field), ("screen", Radius.screen), ("row", Radius.row),
    ]

    private static let spacings: [(String, CGFloat)] = [
        ("hair", Spacing.hair), ("tight", Spacing.tight), ("glyph", Spacing.glyph), ("item", Spacing.item), ("group", Spacing.group),
        ("block", Spacing.block), ("part", Spacing.part), ("sheet", Spacing.sheet), ("inset", Spacing.inset), ("panel", Spacing.panel),
        ("page", Spacing.page), ("section", Spacing.section), ("vacant", Spacing.vacant), ("reading", Spacing.reading),
        ("replyBottom", Spacing.replyBottom),
    ] + platformSpacings

    #if os(macOS)
    private static let platformSpacings: [(String, CGFloat)] = [("pageTop", Spacing.pageTop)]
    #else
    private static let platformSpacings: [(String, CGFloat)] = []
    #endif

    private static let motions = ([
        ("nudge", Motion.nudge), ("travel", Motion.travel), ("glide", Motion.glide), ("fade", Motion.fade),
        ("yield", Motion.yield), ("press", Motion.press), ("release", Motion.release),
    ] as [(String, Animation)]).map(\.0)
}
#endif
