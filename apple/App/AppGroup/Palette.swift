import SwiftUI

/// CuePad 的全部颜色，唯一出处：App、小组件、分享扩展共用。色值与 `.opacity` 叠色只写在这里，界面只取令牌（`lint.sh` 查）。
///
/// 底子是纸与墨（logo、吉祥物的两种颜色）：侧栏 < 桌面 < 纸同一色温由深到浅，文字、图标、系统控件的 tint 都是墨，墨分三档。
/// 深色是"夜里的纸"：暖黑的桌面、略亮的纸、更深的侧栏，三层靠明度分开；彩色在深色下提亮一档，实底压到中等明度配浅字。
/// **签名色是靛青**，只给焦点与正在发生的事：选中、主按钮、焦点环、Agent 在跑、图标点睛点亮；一屏通常一两处，不做装饰、不做链接。
/// 状态色三种各管一件事：等你确认赭黄、出错胭脂、有新回复石绿，只上状态图形与紧挨着的那个词。项目色只上图形，不写成字。
/// 增强对比度时加深次要墨色、描边与靛青。各令牌的 WCAG 对比度写在它的注释里（在侧栏、桌面、纸、气泡四层上最差的那个）。
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

    // MARK: 层（由后到前：侧栏 → 桌面 → 纸）

    var sidebar: Color { dark ? Color(hex: 0x141210) : Color(hex: 0xE6E2DB) }
    /// 页面底，也是小组件与分享扩展的底。iOS 启动屏的底色（资源目录的 LaunchBackground）与它同值：启动屏只认资源目录里的颜色，不同的话冷启动先白后米一闪。
    var desk: Color { dark ? Color(hex: 0x1B1916) : Color(hex: 0xEFEDE8) }
    var paper: Color { dark ? Color(hex: 0x282420) : Color(hex: 0xFCFBF8) }
    /// 纸的上沿：比纸略亮一点，纸面从上往下极轻地过渡到纸色，像有一层向上的光（`paper()`）；也是 Mac 任务浮窗选中的那一行。
    var paperLit: Color { dark ? Color(hex: 0x2E2A25) : Color(hex: 0xFFFFFD) }
    /// 纸和玻璃上沿的一线高光。
    var sheen: Color { Color.white.opacity(dark ? 0.07 : 0.9) }

    /// 你的话的气泡底：比桌面深一级的暖灰（牛皮纸）、字是墨——回答才是会话页的主角，你的话不该是一屏最重的一块；
    /// 深色是比纸略抬升的暖深色、字仍是墨。
    var bubble: Color { dark ? Color(hex: 0x3A352F) : Color(hex: 0xE3DED4) }
    /// 气泡的描边（你的、Cue 的同一种）：只在增强对比度时有。平时气泡与桌面靠明度分开（Cue 的纸亮一级、你的牛皮纸深一级），
    /// 不描边：长对话滚动时每颗多一层，逐帧都要更新。
    var bubbleEdge: Color? { highContrast ? ink.opacity(0.22) : nil }

    // MARK: 玻璃上的字（`GlassInk`）

    /// 写着要读的字的玻璃的着色：深色压一层暗色调，背后的亮字糊开后不再和上面的次要字同亮；浅色垫一层淡纸色。
    var legibleGlass: Color { dark ? Color.black.opacity(0.4) : paper.opacity(0.45) }
    /// 浮在一整片字上的玻璃里垫的九成实的页面底色：背后的字透不过来。
    var solidGlass: Color { desk.opacity(0.9) }

    // MARK: 墨

    /// 正文、标题、图标、系统控件的 tint、链接（加下划线）。对比度 13.3，深色 10。
    var ink: Color { dark ? Color(hex: 0xEEE9E1) : Color(hex: 0x1C1B19) }
    /// 次要文字、图标点睛平时的颜色。对比度 5.6，深色 5.8。
    var ink2: Color { ink.opacity(highContrast ? 0.85 : 0.7) }
    /// 时间、计数、占位字、已结束、待办圈：只扫一眼的。对比度 3.6，深色 4.2。
    var ink3: Color { ink.opacity(highContrast ? 0.7 : 0.55) }
    /// 分隔线、纸边、次按钮描边：装饰，不承载信息。
    var hair: Color { ink.opacity(highContrast ? 0.3 : (dark ? 0.09 : 0.07)) }
    /// 唯一的浅底：悬停、按下、次按钮、代码与变量。
    var fill: Color { ink.opacity(dark ? 0.07 : 0.05) }
    /// 没填满的轨道：用量条、档位条的空格、转圈与头像外圈的轨道。
    var track: Color { ink.opacity(highContrast ? 0.3 : (dark ? 0.16 : 0.14)) }
    /// 模态浮层下面压暗整窗的底（Mac 的 ⌘K、窗口内浮层）。
    var backdrop: Color { Color.black.opacity(dark ? 0.35 : 0.18) }
    /// 浮起的东西的投影：悬停的卡片、提示横幅、抬起的纸。
    var shadow: Color { Color.black.opacity(dark ? 0.3 : 0.08) }
    /// 窗口内浮层的投影：比 `shadow` 重，浮层要从整窗里浮出来。
    var panelShadow: Color { Color.black.opacity(dark ? 0.45 : 0.18) }

    // MARK: 照片与视频上

    /// 压在照片、视频上的图标（播放、移除）：照片的明暗不随外观变，固定白。
    var onMedia: Color { .white }
    /// 照片上图标下面垫的暗底。
    var mediaScrim: Color { Color.black.opacity(0.55) }
    /// 深色下给附图压暗一层，亮图不刺眼；浅色不压。
    var mediaDim: Color { dark ? Color.black.opacity(0.14) : .clear }

    // MARK: 签名色

    /// 靛青：焦点与正在发生（选中、高亮钮的字、焦点环、Agent 在跑、图标点睛点亮）。对比度 6.3，深色 5.1，增强对比度 ≥ 8。
    var signature: Color {
        switch (dark, highContrast) {
        case (false, false): Color(hex: 0x2F4A9E)
        case (false, true): Color(hex: 0x243A80)
        case (true, false): Color(hex: 0x8FA8E2)
        case (true, true): Color(hex: 0xB3C4F0)
        }
    }
    /// 主按钮、发送钮的靛青底：浅色就是签名色；深色压到中等明度——深色的签名色是给字与焦点用的浅靛青，铺成实心钮是一块亮斑。
    /// 钮上的字（`onFill`）8.0，深色 5.4，深色增强对比度 6.0。
    var signatureFill: Color {
        switch (dark, highContrast) {
        case (false, _): signature
        case (true, false): Color(hex: Self.indigoMid)
        case (true, true): Color(hex: 0x3F5AAE)
        }
    }
    /// 选中的底：侧栏与列表的当前项、选中的胶囊；字保持墨色。
    var selection: Color { signature.opacity(highContrast ? 0.28 : (dark ? 0.2 : 0.12)) }
    /// 搜索命中的字垫的底：命中是在构造富文本时标的、拿不到外观，两种外观共用一份中等明度的靛青（浅纸上是淡蓝、暗纸上是暗蓝）。
    static let searchMatch = Color(hex: indigoMid).opacity(0.22)
    private static let indigoMid: UInt32 = 0x4A64B8

    /// 靛青、胭脂实底上的字与图标：暖白。
    var onFill: Color { Color(hex: 0xFFFDF8) }

    // MARK: 状态（只上状态图形与紧挨着的那个词，不给整段字上色）

    /// 等你确认：赭黄，全 App 只有等你用它（问号圆、"等你 N"、Cue 头像的环）；表达等你经 Waiting.swift。对比度 4.7，深色 6.9。
    var waiting: Color { dark ? Color(hex: 0xEDBD57) : Color(hex: 0x845A06) }
    /// 出错与没能送达：胭脂（`Failure`）。对比度 5.0，深色 4.6。
    var failure: Color { dark ? Color(hex: 0xF0789E) : Color(hex: 0xAD2B5C) }
    /// 删除钮、轻扫删除的胭脂底。字 6.3，深色 5.6。
    var failureFill: Color { dark ? Color(hex: 0xB8325F) : Color(hex: 0xAD2B5C) }
    /// 用量快满了的那段轨道。
    var failureTrack: Color { failure.opacity(0.2) }
    /// 有新回复（这轮答完了、你还没看）：石绿。对比度 4.7，深色 5.0，增强对比度 ≥ 7。
    var replied: Color {
        switch (dark, highContrast) {
        case (false, false): Color(hex: 0x17704A)
        case (false, true): Color(hex: 0x156343)
        case (true, false): Color(hex: 0x55B988)
        case (true, true): Color(hex: 0x8FDCB2)
        }
    }
    /// 要你看的会话卡片铺的一层很淡的状态色（`PiShown.wash`）。
    func wash(_ status: Color) -> Color { status.opacity(dark ? 0.08 : 0.07) }

    // MARK: 轻扫露出的其余动作（删除是 `failureFill`、主动作是 `signatureFill`）

    var neutralFill: Color { dark ? Color(hex: 0x6E685F) : Color(hex: 0x3A3733) }
    /// 安静的一档，比 `neutralFill` 浅。
    var quietFill: Color { dark ? Color(hex: 0x57524B) : Color(hex: 0x6E685F) }

    // MARK: 项目色

    /// 项目可选的颜色。`stored` 是库里存的值（不迁移），显示时按深浅取一档：浅色对三层 ≥ 3.2，深色 ≥ 5.3。
    /// 没有靛蓝一路：与签名色色相太近，项目会被读成焦点。黄偏橄榄（芥黄），和等你的赭黄分开。
    struct ProjectColor {
        let stored: String
        let name: String
        fileprivate let light: UInt32
        fileprivate let dark: UInt32
    }

    static let projectColors = [
        ProjectColor(stored: "#D9774B", name: "橙色", light: 0xC0603A, dark: 0xE08A62),
        ProjectColor(stored: "#C9A227", name: "芥黄", light: 0x858024, dark: 0xCFC45E),
        ProjectColor(stored: "#5E9E5A", name: "绿色", light: 0x4F8A4C, dark: 0x7DB878),
        ProjectColor(stored: "#3F8FB8", name: "蓝色", light: 0x357DA3, dark: 0x6AAAD0),
        ProjectColor(stored: "#3AA088", name: "青绿", light: 0x2E8A75, dark: 0x5CBBA3),
        ProjectColor(stored: "#A260C4", name: "紫色", light: 0x9358B3, dark: 0xB585D6),
        ProjectColor(stored: "#D0607D", name: "粉色", light: 0xC2577A, dark: 0xE07E9A),
        ProjectColor(stored: "#8A8A84", name: "灰色", light: 0x7D7A73, dark: 0xA39F96),
    ]

    /// 项目的颜色：只上图形（项目图标、任务行末的项目小图标），不写成字、不做成圆点。不在表里的旧值退回灰色。
    func project(_ stored: String) -> Color {
        let entry = Self.projectColors.first { $0.stored.caseInsensitiveCompare(stored) == .orderedSame } ?? Self.projectColors[7]
        return Color(hex: dark ? entry.dark : entry.light)
    }

    /// 项目色铺的淡底（书架的项目卡、项目行的图标底）。
    func projectWash(_ stored: String) -> Color { project(stored).opacity(dark ? 0.16 : 0.1) }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// 环境里的配色；根视图按外观与对比度注入（`withPalette()`）。
private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(dark: false)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// 按外观、对比度注入 `palette`，并把墨设为系统控件的 tint（选中、焦点、开关、系统按钮）。每个根视图挂一次。
    func withPalette() -> some View { modifier(PaletteReader()) }
}

private struct PaletteReader: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let palette = Palette(scheme, contrast: contrast)
        content.environment(\.palette, palette).tint(palette.ink)
    }
}
