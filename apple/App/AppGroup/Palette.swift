import SwiftUI

struct Palette {
    let dark: Bool
    let highContrast: Bool

    init(dark: Bool, highContrast: Bool = false) {
        self.dark = dark
        self.highContrast = highContrast
    }

    init(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) {
        self.init(dark: scheme == .dark, highContrast: contrast == .increased)
    }


    var sidebar: Color { dark ? Color(hex: 0x141210) : Color(hex: 0xE6E2DB) }
    /// 页面底，也是小组件与分享扩展的底。
    var desk: Color { dark ? Color(hex: 0x1B1916) : Color(hex: 0xEFEDE8) }
    var paper: Color { dark ? Color(hex: 0x282420) : Color(hex: 0xFCFBF8) }
    var paperLit: Color { dark ? Color(hex: 0x2E2A25) : Color(hex: 0xFFFFFD) }
    var sheen: Color { Color.white.opacity(dark ? 0.07 : 0.9) }

    var bubble: Color { dark ? Color(hex: 0x3A352F) : Color(hex: 0xE3DED4) }
    var bubbleEdge: Color? { highContrast ? ink.opacity(0.22) : nil }


    var glassTint: Color { dark ? Color.black.opacity(0.4) : paper.opacity(0.45) }
    var solidGlass: Color { desk.opacity(0.9) }
    var veilGlass: Color { desk.opacity(dark ? 0.72 : 0.6) }
    var inkWell: Color { desk.opacity(dark ? 0.78 : 0.3) }


    var ink: Color { dark ? Color(hex: 0xEEE9E1) : Color(hex: 0x1C1B19) }
    var ink2: Color { ink.opacity(highContrast ? 0.9 : 0.78) }
    var ink3: Color { ink.opacity(highContrast ? 0.75 : (dark ? 0.6 : 0.64)) }
    var hair: Color { ink.opacity(highContrast ? 0.3 : (dark ? 0.09 : 0.07)) }
    var fill: Color { ink.opacity(fillAmount) }
    private var fillAmount: Double { dark ? 0.07 : 0.05 }
    var track: Color { ink.opacity(highContrast ? 0.3 : (dark ? 0.16 : 0.14)) }
    /// 开门那只环（`CueOpening`）：一圈黑管子，从上往下受光、压暗再在下沿返一点光；墨色上用，浅深外观同一套。
    var ringTube: [Color] { [Color(hex: 0x77706A), Color(hex: 0x2B2825), Color(hex: 0x0D0C0B), Color(hex: 0x050505), Color(hex: 0x3A3531)] }
    var backdrop: Color { Color.black.opacity(dark ? 0.35 : 0.18) }
    var stale: Color { desk.opacity(dark ? 0.62 : 0.55) }
    var shadow: Color { Color.black.opacity(dark ? 0.3 : 0.08) }
    var panelShadow: Color { Color.black.opacity(dark ? 0.45 : 0.18) }


    var onMedia: Color { .white }
    var mediaScrim: Color { Color.black.opacity(0.55) }
    var mediaGround: Color { .white }
    var mediaEdge: Color {
        switch (dark, highContrast) {
        case (false, false): Color(hex: 0xE3E2DF)
        case (false, true): Color(hex: 0x8F8D88)
        case (true, false): Color(hex: 0x3E3A36)
        case (true, true): Color(hex: 0x77726B)
        }
    }
    var mediaDim: Color { dark ? Color.black.opacity(0.14) : .clear }


    var signature: Color {
        switch (dark, highContrast) {
        case (false, false): Color(hex: 0x2F4A9E)
        case (false, true): Color(hex: 0x243A80)
        case (true, false): Color(hex: 0x8FA8E2)
        case (true, true): Color(hex: 0xB3C4F0)
        }
    }
    var signatureSoft: Color { signature.opacity(0.7) }
    var signatureFill: Color {
        switch (dark, highContrast) {
        case (false, _): signature
        case (true, false): Color(hex: Self.indigoMid)
        case (true, true): Color(hex: 0x3F5AAE)
        }
    }
    var selection: Color { ink.opacity(highContrast ? 0.22 : (dark ? 0.14 : 0.09)) }
    static let searchMatch = Color(hex: indigoMid).opacity(0.22)
    private static let indigoMid: UInt32 = 0x4A64B8

    var onFill: Color { Color(hex: 0xFFFDF8) }
    var action: Color { ink }
    var onAction: Color { paper }

    struct Signal {
        let fill: Color
        let ink: Color
        let soft: Color

        fileprivate init(fill: Color, ink: Color) {
            self.fill = fill
            self.ink = ink
            soft = ink.opacity(0.82)
        }
    }

    func signal(_ tone: CueNow.Tone) -> Signal {
        switch tone {
        case .asks: Signal(fill: Color(hex: 0xEDBD57), ink: Color(hex: 0x2A1F06))
        case .reply, .done: Signal(fill: Color(hex: 0x55B988), ink: Color(hex: 0x0C2619))
        case .moving: Signal(fill: Color(hex: 0x3852A8), ink: onFill)
        case .quiet: Signal(fill: paper, ink: ink)
        }
    }


    var waiting: Color { dark ? Color(hex: 0xEDBD57) : Color(hex: 0x845A06) }
    var waitingFill: Color { dark ? Color(hex: 0x9C6A08) : Color(hex: 0x845A06) }
    var thinkingLow: Color { dark ? Color(hex: 0x4566D6) : Color(hex: 0x2F4FB8) }
    var thinkingMid: Color { dark ? Color(hex: 0x8A55D2) : Color(hex: 0x7A45C6) }
    var thinkingHigh: Color { dark ? Color(hex: 0xC8457C) : Color(hex: 0xC8396F) }
    var thinkingSpark: Color { Color(hex: 0xFFD08A) }

    var thinkingRim: Color { Color.white.opacity(0.45) }

    func thinking(_ energy: Double) -> Color {
        energy < 0.5 ? thinkingLow.mix(with: thinkingMid, by: energy * 2) : thinkingMid.mix(with: thinkingHigh, by: energy * 2 - 1)
    }
    func thinkingInk(_ energy: Double) -> Color { dark ? thinking(energy).mix(with: .white, by: 0.4) : thinking(energy) }
    var failure: Color { dark ? Color(hex: 0xF0789E) : Color(hex: 0xAD2B5C) }
    var failureFill: Color { dark ? Color(hex: 0xB8325F) : Color(hex: 0xAD2B5C) }
    var replied: Color {
        switch (dark, highContrast) {
        case (false, false): Color(hex: 0x17704A)
        case (false, true): Color(hex: 0x156343)
        case (true, false): Color(hex: 0x55B988)
        case (true, true): Color(hex: 0x8FDCB2)
        }
    }

    var failureWash: Color { dark ? Color(hex: 0x382A2E) : Color(hex: 0xFBEDF0) }
    var repliedWash: Color { dark ? Color(hex: 0x26382D) : Color(hex: 0xE2F1E7) }
    var signatureWash: Color { dark ? Color(hex: 0x262C3D) : Color(hex: 0xE5E9F5) }

    var diffAdded: Color { repliedWash }
    var diffRemoved: Color { failureWash }


    var waitingPaper: Color { dark ? Color(hex: 0x332C21) : Color(hex: 0xFBF4E4) }


    var neutralFill: Color { dark ? Color(hex: 0x6E685F) : Color(hex: 0x3A3733) }
    var quietFill: Color { dark ? Color(hex: 0x57524B) : Color(hex: 0x6E685F) }


    struct ProjectColor {
        let stored: String
        let name: String
        fileprivate let light: UInt32
        fileprivate let dark: UInt32
    }

    static let projectColors = [
        ProjectColor(stored: "#D9774B", name: String(localized: "橙色"), light: 0xC0603A, dark: 0xE08A62),
        ProjectColor(stored: "#C9A227", name: String(localized: "芥黄"), light: 0x858024, dark: 0xCFC45E),
        ProjectColor(stored: "#5E9E5A", name: String(localized: "绿色"), light: 0x4F8A4C, dark: 0x7DB878),
        ProjectColor(stored: "#3F8FB8", name: String(localized: "蓝色"), light: 0x357DA3, dark: 0x6AAAD0),
        ProjectColor(stored: "#3AA088", name: String(localized: "青绿"), light: 0x2E8A75, dark: 0x5CBBA3),
        ProjectColor(stored: "#A260C4", name: String(localized: "紫色"), light: 0x9358B3, dark: 0xB585D6),
        ProjectColor(stored: "#D0607D", name: String(localized: "粉色"), light: 0xC2577A, dark: 0xE07E9A),
        ProjectColor(stored: "#8A8A84", name: String(localized: "灰色"), light: 0x7D7A73, dark: 0xA39F96),
    ]

    static let neutralProject = "#8A8A84"
    private static let fallbackProjectColor = projectColors.first { $0.stored == neutralProject }!

    func project(_ stored: String) -> Color {
        let entry = Self.projectColors.first { $0.stored.caseInsensitiveCompare(stored) == .orderedSame } ?? Self.fallbackProjectColor
        return Color(hex: dark ? entry.dark : entry.light)
    }

    var note: Color { paper.mix(with: Color(hex: dark ? 0xB8A27A : 0x9A8257), by: dark ? 0.12 : 0.1, in: .device) }
}

private extension Color {
    nonisolated init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Color {
    nonisolated static func webPage(_ css: String) -> Color? {
        let parts = css.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        return Color(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255)
    }
}

extension EnvironmentValues {
    /// 环境里的配色：只由外观与对比度算出，不另存一份、不靠谁注入。系统把这两样带进每一层（sheet、全屏、窗口那一层的气泡与浮出、
    /// 导航栏与菜单的预览、另起的托管视图、小组件与扩展），哪一层都拿到对的配色；要按某种外观画就改外观（`colorScheme`），不改配色。
    /// 否决过注入一份：注入点之外的层（窗口那一层的气泡挂在根视图外面）拿到默认的浅色，深色下浅纸上写着浅墨，整块发白读不出。
    var palette: Palette { Palette(colorScheme, contrast: colorSchemeContrast) }
}

extension View {
    func withPalette() -> some View { modifier(PaletteReader()) }
}

private struct PaletteReader: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.tint(palette.ink)
    }
}
