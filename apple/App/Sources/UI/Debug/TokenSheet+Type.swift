#if DEBUG
import SwiftUI

extension TokenSheet {
    var typography: some View {
        group("Typography") {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(Self.fonts, id: \.0) { name, font in
                    Text(verbatim: name).font(font).lineLimit(1)
                }
            }
        }
    }

    var glyphs: some View {
        group("Glyph") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.glyphCell), spacing: Spacing.item, alignment: .bottom)], spacing: Spacing.group) {
                ForEach(Self.glyphs, id: \.0) { name, font in
                    VStack(spacing: Spacing.hair) {
                        Image(.add).font(font)
                        label(name)
                    }
                }
            }
        }
    }

    private static let glyphCell: CGFloat = 112

    private static let glyphs: [(String, Font)] = [
        ("mark", Glyph.mark), ("at", Glyph.at(Glyph.chevronSize)), ("project", Glyph.project(Glyph.chevronSize)), ("small", Glyph.small), ("row", Glyph.row),
        ("control", Glyph.control), ("controlBold", Glyph.controlBold), ("large", Glyph.large), ("projectIdentity", .system(size: Glyph.projectIdentity)), ("hero", Glyph.hero),
    ]

    private static let fonts: [(String, Font)] = [
        ("body", Typography.body), ("bodyBold", Typography.bodyBold), ("bodyStrong", Typography.bodyStrong),
        ("secondary", Typography.secondary), ("secondaryBold", Typography.secondaryBold), ("meta", Typography.meta), ("metaBold", Typography.metaBold),
        ("label", Typography.label), ("caption", Typography.caption), ("captionBold", Typography.captionBold),
        ("caption2", Typography.caption2), ("caption2Bold", Typography.caption2Bold),
        ("reading", Typography.reading), ("readingBold", Typography.readingBold), ("readingHeading", Typography.readingHeading),
        ("code", Typography.code), ("codeNote", Typography.codeNote), ("inlineCode", Typography.inlineCode),
        ("title", Typography.title), ("sectionTitle", Typography.sectionTitle), ("sectionCount", Typography.sectionCount),
        ("heading", Typography.heading), ("emptyTitle", Typography.emptyTitle), ("cueCardName", Typography.cueCardName), ("gaugeNumber", Typography.gaugeNumber),
        ("toolbarLabel", Typography.toolbarLabel), ("toolbarTitle", Typography.toolbarTitle),
        ("toolbarTitlePaired", Typography.toolbarTitlePaired), ("toolbarSubtitle", Typography.toolbarSubtitle),
        ("laneTitle", Typography.laneTitle),
        ("diff", Typography.diff), ("diffStrong", Typography.diffStrong),
        ("documentTitle", Typography.documentTitle), ("documentHeading", Typography.documentHeading),
    ] + platformFonts

    #if os(macOS)
    private static let platformFonts: [(String, Font)] = [
        ("searchField", Typography.searchField), ("previewTitle", Typography.previewTitle), ("keycap", Typography.keycap),
        ("menuBarCount", Font(Typography.menuBarCount)),
    ]
    #else
    private static let platformFonts: [(String, Font)] = [("codeUIFont", Font(Typography.codeUIFont)), ("cueCardNameCompact", Typography.cueCardNameCompact)]
    #endif
}
#endif
