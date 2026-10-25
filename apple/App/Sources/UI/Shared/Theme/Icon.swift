import CueEditor
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 全 App 的图标，按意思取名，全是自家的墨块符号（cue.*，由 design/tools/cue-symbols.py 生成）；哪个意思画成哪个符号只在 `source` 一处写。
/// 别处不写符号名，全 App 不用系统符号（lint 拦）：界面用 `Image(_:)`、`Label(_:icon:)`、`Button(_:icon:)`、`Menu(_:icon:)`，
/// UIKit、AppKit 的菜单与工具条用 `platformImage`。品牌标志（`BrandMark`）不在这里；项目图标走 `project`（闭合表 `ProjectIcon`）。
///
/// 着色（墨块符号的第二层是点睛，只是小部件，主体都在主层，见 design/tools/cue-symbols.py）：
/// - 平时点睛是这一处前景色的次一级（层级渲染：墨色前景时就是次墨），不用另上色；单色场合（系统菜单、工具栏）照系统。
/// - 选中或正在发生时点睛靛青、状态图标的点按状态色（调色板渲染）：用 `IconImage(_:accent:)`，只在那个状态存在时给。
/// - 反白符号（`filled`）不按层着色，调用方给两种颜色时按层上色。
nonisolated enum Icon: Hashable, Sendable {
    // 导航与页面入口
    case cue, cueAsleep, cueLooking, cueHappy
    case idea, task, session, search, settings, archive, trash, sidebar
    case agent, all, filter, extensionNote
    // 状态
    case waiting, cueAsking, awaitsReply, failure, undelivered, onTheWay, replied, yourTurn, fresh, ended, interrupted, unknown, gone
    case done, donePending, picked
    case syncStarting, synced, syncing, syncOff, syncRestricted, syncTrouble, syncPaused, uploadLocal, replaceWithCloud, syncNow
    case alertsPending, alertsOn, alertsOff
    // 任务与卡片操作
    case complete, reopen, restore, start, add, indent, outdent, link, unlink
    case projects, folder, newProject, unbindFolder, pin, unpin
    case copy, share, saveAsIdea, write, rename, close, remove, clear, more
    case forward, back, expand, collapse, choose, conflict
    // 输入、发送与会话
    case send, save, checked, stop, endSession, handOff, delivered, retry, toLatest, fetching, compact, renew
    case declined, mac, yourAnswer, above, floated, earlier
    case photo, photoLibrary, camera, pickCards, expandEdit, selectText, dismissKeyboard, variables
    case terminal, terminalWindow, readFile, editFile, pondering, tool, said, started, added, branch, markUnread, fireCode, thinking
    case subagent
    // Cue 与设置
    case memory, wakeEnabled, wakeMessage, wakeActivity, wakeIdle, wakeReminder, looked, mail
    case name, hotkey, talkToCue, appearance, updates
    // 文件与交付物：没有画面的音频、列表里的文字卡、还在下载、视频的播放标、认不出类型的文件、转动查看 3D 模型
    case audio, document, downloading, play, file, inspect3D
    /// Mac 菜单栏里的 CuePad（单色模板图）。
    case menuBar
    case project(ProjectIcon)

    private enum Source {
        /// 自家的墨块符号（资源 Symbols/cue.<名>）。
        case ink(String)
        /// 自家的反白符号：记号在第一层、实心底在第二层（同系统的 *.circle.fill），不按层级渲染，调用方给两种颜色时按层上色。
        case filled(String)
    }

    private var source: Source {
        switch self {
        case .cue: .ink("mascot")
        case .cueAsleep: .ink("mascot.sleep")
        case .cueLooking: .ink("mascot.look")
        case .cueHappy: .ink("mascot.happy")
        case .idea: .ink("idea")
        case .task: .ink("task")
        case .session: .ink("session")
        case .search: .ink("search")
        case .settings: .ink("settings")
        case .archive: .ink("archive")
        case .trash: .ink("trash")
        case .sidebar: .ink("sidebar")
        case .add: .ink("plus")
        case .close, .remove: .ink("close")
        case .clear: .ink("clear")
        case .more, .pondering: .ink("more")
        case .forward: .ink("chevron.right")
        case .back: .ink("chevron.left")
        case .expand: .ink("chevron.down")
        case .collapse: .ink("chevron.up")
        case .send: .ink("plane")
        case .stop: .ink("stop")
        case .done, .complete: .ink("done")
        case .donePending: .ink("done.pre")
        case .onTheWay: .ink("plane")
        case .agent: .ink("agent")
        case .waiting: .ink("waiting")
        case .cueAsking: .ink("asking")
        case .failure: .ink("failure")
        case .undelivered: .ink("undelivered")
        case .replied, .alertsPending: .ink("bell")
        case .yourTurn: .ink("cursor")
        case .fresh: .ink("sparkle")
        // 已结束的会话、点了去的那一处已不在：都是那里已经没有了
        case .ended, .gone: .ink("ended")
        case .interrupted: .ink("interrupted")
        case .unknown: .ink("unknown")
        case .picked: .filled("picked")
        case .syncStarting: .ink("cloud")
        case .synced: .ink("cloud.done")
        case .syncing: .ink("cloud.sync")
        case .syncOff: .ink("cloud.off")
        case .syncRestricted: .ink("cloud.lock")
        case .syncTrouble: .ink("cloud.alert")
        case .syncPaused: .ink("cloud.pause")
        case .uploadLocal: .ink("cloud.up")
        case .replaceWithCloud: .ink("cloud.down")
        case .syncNow, .renew: .ink("renew")
        case .alertsOn: .ink("bell.on")
        case .alertsOff: .ink("bell.off")
        case .reopen: .ink("reopen")
        case .restore: .ink("restore")
        case .start, .play: .ink("play")
        case .indent: .ink("indent")
        case .outdent: .ink("outdent")
        case .link: .ink("link")
        case .unlink: .ink("unlink")
        case .folder, .projects: .ink("folder")
        case .newProject: .ink("folder.add")
        case .unbindFolder: .ink("folder.remove")
        case .pin: .ink("pin")
        case .unpin: .ink("unpin")
        case .copy: .ink("copy")
        case .conflict: .ink("conflict")
        case .share: .ink("share")
        case .saveAsIdea: .ink("save")
        case .write: .ink("write")
        case .rename, .editFile: .ink("pencil")
        case .choose: .ink("choose")
        case .all: .ink("deck")
        case .filter: .ink("filter")
        case .extensionNote: .ink("puzzle")

        case .save, .checked: .ink("tick")
        case .endSession: .ink("ring.stop")
        case .handOff: .ink("plane")
        case .delivered: .ink("plane.done")
        case .retry: .ink("reload")
        case .toLatest: .ink("arrow.down")
        case .fetching: .ink("ring.down")
        case .compact: .ink("compact")
        case .declined: .ink("hand")
        case .mac: .ink("mac")
        case .yourAnswer: .ink("restore")
        case .above, .floated, .earlier: .ink("arrow.up")
        case .photo: .ink("photo")
        case .photoLibrary: .ink("photos")
        case .camera: .ink("camera")
        case .pickCards: .ink("conflict")
        case .expandEdit: .ink("cursor")
        case .selectText: .ink("select")
        case .dismissKeyboard: .ink("keyboard.down")
        case .variables: .ink("braces")
        case .terminal: .ink("terminal")
        case .terminalWindow: .ink("window")
        case .readFile: .ink("doc")
        case .tool: .ink("wrench")
        case .said: .ink("bubble.text")
        case .started: .ink("ring.play")
        case .added: .ink("ring.plus")
        case .branch: .ink("branch")
        case .markUnread, .awaitsReply: .ink("dot")
        case .fireCode: .ink("flame")
        case .thinking: .ink("bubble.dots")
        case .subagent: .ink("person")
        case .memory: .ink("bookmark")
        case .wakeEnabled: .ink("power")
        case .wakeActivity: .ink("bolt")
        case .wakeMessage, .talkToCue: .ink("bubble")
        case .wakeIdle, .looked: .ink("eye")
        case .wakeReminder: .ink("alarm")
        case .mail: .ink("mail")
        case .name: .ink("tag")
        case .hotkey: .ink("keyboard")
        case .appearance: .ink("sun")
        case .updates: .ink("badge.down")
        case .audio: .ink("wave")
        case .document: .ink("doc")
        case .downloading: .ink("cloud.down")
        case .file: .ink("doc.blank")
        case .inspect3D: .ink("cube")
        case .menuBar: .ink("menubar")
        case .project(let icon): .ink(icon.symbol)
        }
    }

    /// 有点睛层、按上面的着色规则画的墨块符号（反白符号不是）。
    var isInk: Bool { if case .ink = source { true } else { false } }

    /// Cue 此刻的表情用哪个符号（标签图标；头像是位图，见 `CueAvatar`）：睡着闭眼、在做事看向一边、刚做完开心，其余醒着。
    static func cue(_ mood: CueMood) -> Icon {
        switch mood {
        case .sleeping: .cueAsleep
        case .thinking: .cueLooking
        case .done: .cueHappy
        case .waiting, .listening: .cue
        }
    }

    #if os(iOS)
    /// UIKit 的菜单与工具条用。
    var platformImage: UIImage? {
        switch source {
        case .ink(let name), .filled(let name): UIImage(named: Self.ink(name))
        }
    }
    #else
    /// AppKit 的菜单与工具条用。
    var platformImage: NSImage? {
        switch source {
        case .ink(let name), .filled(let name): NSImage(symbolName: Self.ink(name), bundle: .main, variableValue: 0)
        }
    }
    #endif

    fileprivate var image: Image {
        switch source {
        // 层级渲染：点睛是前景色的次一级。写在 Image 上，外面再设渲染方式也不覆盖它（要点亮用 `IconImage`）
        case .ink(let name): Image(Self.ink(name)).symbolRenderingMode(.hierarchical)
        case .filled(let name): Image(Self.ink(name))
        }
    }

    /// 调色板渲染的墨块符号：主体、点睛各取外面给的一种颜色（`IconImage`）。
    fileprivate var paletteImage: Image {
        guard case .ink(let name) = source else { return image }
        return Image(Self.ink(name)).symbolRenderingMode(.palette)
    }

    private static func ink(_ name: String) -> String { "cue." + name }
}

nonisolated private extension ProjectIcon {
    var symbol: String {
        switch self {
        case .folder: "folder"
        case .sparkles: "sparkle"
        case .chat: "bubbles"
        case .terminal: "terminal"
        case .globe: "globe"
        case .hammer: "hammer"
        case .book: "books"
        case .target: "target"
        case .briefcase: "briefcase"
        case .cart: "cart"
        case .megaphone: "megaphone"
        case .paintbrush: "brush"
        case .lightbulb: "idea"
        case .flag: "flag"
        case .cube: "cube"
        case .leaf: "leaf"
        case .layers: "layers"
        case .camera: "camera"
        case .house: "house"
        case .heart: "heart"
        case .star: "star"
        case .music: "music"
        case .rocket: "rocket"
        case .bolt: "bolt"
        }
    }
}

/// `Label` 等的泛型参数也叫 Icon，扩展里用这个名字指本类型。
typealias AppIcon = Icon

extension Image {
    init(_ icon: Icon) { self = icon.image }
}

/// 点睛上色的图标（着色规则只在这里）：平时同 `Image(_:)`，点睛是前景色的次一级；`lit`（选中、正在发生）点睛靛青；
/// `state(色)` 是状态图标的点按状态色（等你赭黄…），只在那个状态存在时给。主体照外面的前景色。反白符号不点亮，整个照前景色。
struct IconImage: View {
    enum Accent: Equatable {
        case none, lit
        case state(Color)
    }

    let icon: Icon
    var accent = Accent.none
    @Environment(\.palette) private var palette

    init(_ icon: Icon, accent: Accent = .none) {
        self.icon = icon
        self.accent = accent
    }

    var body: some View {
        if let color, icon.isInk {
            icon.paletteImage.foregroundStyle(HierarchicalShapeStyle.primary, color)
        } else {
            Image(icon)
        }
    }

    private var color: Color? {
        switch accent {
        case .none: nil
        case .lit: palette.signature
        case .state(let color): color
        }
    }
}

/// Cue 的标签图标（iPad 工具栏的 Cue 面板钮）：表情跟着 `CueMood`（`Icon.cue(_:)`），被叫醒、做完时软糖地弹一下、在最低点换表情（`Jelly`）。
/// 点睛（折角）：有等你时赭黄；选中、话在路上或在做事时靛青。
struct CueMark: View {
    var selected = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        let accent: IconImage.Accent = cue.waiting > 0 ? .state(palette.waiting) : selected || cue.busy ? .lit : .none
        Jelly(value: cue.expression, move: JellyMove.cue) { mood, _ in IconImage(.cue(mood), accent: accent) }
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: LocalizedStringKey, icon: AppIcon) {
        self.init { Text(title) } icon: { Image(icon) }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, icon: AppIcon) {
        self.init { Text(title) } icon: { Image(icon) }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringKey, icon: AppIcon, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, icon: AppIcon, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringKey, icon: AppIcon, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, icon: icon) }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, icon: AppIcon, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, icon: icon) }
    }
}

extension Toggle where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringKey, icon: AppIcon, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { SwiftUI.Label(title, icon: icon) }
    }
}

extension CueSelectionAction {
    init(title: String, icon: Icon, perform: @escaping @MainActor (String) -> Void) {
        self.init(title: title, image: icon.platformImage, perform: perform)
    }
}
