import CueEditor
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 全 App 的图标，按意思取名；图从哪来（自家的墨块符号 cue.*，或还没画到的系统符号）只在 `source` 一处写，往后每批只改这里的映射。
/// 别处不写符号名、不调 `Image(systemName:)` 一类（lint 拦）：界面用 `Image(_:)`、`Label(_:icon:)`、`Button(_:icon:)`、`Menu(_:icon:)`，
/// UIKit、AppKit 的菜单与工具条用 `platformImage`。品牌标志（`BrandMark`）不在这里；项目图标暂按项目存的名字走 `project`（第 5 批收成自家图标表）。
///
/// 着色（墨块符号的第二层是点睛，见 design/tools/cue-symbols.py）：
/// - 平时点睛是这一处前景色的次一级（层级渲染：墨色前景时就是次墨），不用另上色；单色场合（系统菜单、工具栏）照系统。
/// - 选中或正在发生时点睛靛青、状态图标的点按状态色（调色板渲染）：用 `IconImage(_:accent:)`，只在那个状态存在时给。
/// - 系统符号照原样，不受这两条影响。
nonisolated enum Icon: Hashable, Sendable {
    // 导航与页面入口
    case cue, cueAsleep, cueLooking, cueHappy
    case idea, task, session, search, settings, unfiled, archive, trash, sidebar
    case agent, allSessions, all, filter, extensionNote
    // 状态
    case waiting, cueAsking, failure, undelivered, needsReload, onTheWay, replied, yourTurn, resting, fresh, ended, interrupted, unknown
    case done, donePending, picked
    case syncStarting, synced, syncing, syncOff, syncRestricted, syncTrouble, syncPaused, uploadLocal, replaceWithCloud, syncNow
    case alertsPending, alertsOn, alertsOff
    // 任务与卡片操作
    case complete, reopen, restore, start, add, indent, outdent, link, unlink
    case folder, newProject, unbindFolder, folderMissing, resource, isResource, pin, pinned, unpin
    case copy, share, saveAsIdea, write, rename, close, remove, clear, more
    case forward, back, expand, collapse, choose, conflict
    // 输入、发送与会话
    case send, save, checked, stop, endSession, handOff, delivered, steer, queued, retry, toLatest, fetching, compact, renew
    case declined, cannotSend, mac, yourAnswer, sendAnswer, above, floated, earlier
    case photo, photoLibrary, camera, pickCards, expandEdit, selectText, dismissKeyboard, variables
    case terminal, terminalWindow, readFile, editFile, pondering, tool, said, started, added, branch, markUnread, fireCode, thinking
    case researcher, engineer, batchWorker, designer, sentinel, subagent
    // Cue 与设置
    case memory, wakeEnabled, wakeMessage, wakeActivity, wakeIdle, wakeReminder, wakeSettings, mail
    case profile, name, autoApprove, hotkey, talkToCue, appearance, testConnection, updates
    // 文件预览的类型
    case web, markdown, video, audio, pdf, document, spreadsheet, presentation, model, plainText
    /// 项目存的图标名（系统符号名，`ProjectGlyph` 定能认哪些）。
    case project(String)

    private enum Source {
        /// 自家的墨块符号（资源 Symbols/cue.<名>）。
        case ink(String)
        case system(String)
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
        case .unfiled: .ink("inbox")
        case .archive: .ink("archive")
        case .trash: .ink("trash")
        case .sidebar: .ink("sidebar")
        case .add: .ink("plus")
        case .close, .remove: .ink("close")
        case .clear: .ink("clear")
        case .more, .resting, .pondering: .ink("more")
        case .forward: .ink("chevron.right")
        case .back: .ink("chevron.left")
        case .expand: .ink("chevron.down")
        case .collapse: .ink("chevron.up")
        case .send: .ink("send")
        case .stop: .ink("stop")
        case .done: .ink("done")
        case .donePending: .ink("done.pre")
        case .onTheWay: .ink("climb")

        case .agent: .system("sparkles")
        case .allSessions: .system("rectangle.stack")
        case .all: .system("square.stack")
        case .filter: .system("line.3.horizontal.decrease")
        case .extensionNote: .system("puzzlepiece.extension")
        case .waiting: .system("questionmark.circle.fill")
        case .cueAsking: .system("questionmark.bubble")
        case .failure: .system("exclamationmark.circle.fill")
        case .undelivered: .system("arrow.uturn.backward.circle.fill")
        case .needsReload: .system("arrow.clockwise.circle")
        case .replied: .system("bell.fill")
        case .yourTurn: .system("character.cursor.ibeam")
        case .fresh: .system("sparkle")
        case .ended: .system("circle.slash")
        case .interrupted: .system("bolt.slash")
        case .unknown: .system("questionmark.circle")
        case .picked: .system("checkmark.circle.fill")
        case .syncStarting: .system("icloud")
        case .synced: .system("checkmark.icloud")
        case .syncing: .system("arrow.triangle.2.circlepath.icloud")
        case .syncOff: .system("icloud.slash")
        case .syncRestricted: .system("lock.icloud")
        case .syncTrouble: .system("exclamationmark.icloud")
        case .syncPaused: .system("pause.circle")
        case .uploadLocal: .system("icloud.and.arrow.up")
        case .replaceWithCloud: .system("icloud.and.arrow.down")
        case .syncNow, .renew: .system("arrow.triangle.2.circlepath")
        case .alertsPending: .system("bell")
        case .alertsOn: .system("bell.badge")
        case .alertsOff: .system("bell.slash")
        case .complete: .system("checkmark.circle")
        case .reopen: .system("arrow.uturn.backward.circle")
        case .restore: .system("arrow.uturn.backward")
        case .start: .system("play.fill")
        case .indent: .system("increase.indent")
        case .outdent: .system("decrease.indent")
        case .link: .system("link")
        case .unlink: .system("link.badge.minus")
        case .folder: .system("folder")
        case .newProject: .system("folder.badge.plus")
        case .unbindFolder: .system("folder.badge.minus")
        case .folderMissing: .system("folder.badge.questionmark")
        case .resource: .system("books.vertical")
        case .isResource: .system("books.vertical.fill")
        case .pin: .system("pin")
        case .pinned: .system("pin.fill")
        case .unpin: .system("pin.slash")
        case .copy: .system("doc.on.doc")
        case .share: .system("square.and.arrow.up")
        case .saveAsIdea: .system("square.and.arrow.down")
        case .write: .system("square.and.pencil")
        case .rename, .editFile: .system("pencil")
        case .choose: .system("chevron.up.chevron.down")
        case .conflict: .system("square.on.square")
        case .save, .checked: .system("checkmark")
        case .endSession: .system("stop.circle")
        case .handOff: .system("paperplane")
        case .delivered: .system("paperplane.fill")
        case .steer, .wakeActivity: .system("bolt")
        case .queued: .system("clock")
        case .retry: .system("arrow.clockwise")
        case .toLatest: .system("arrow.down")
        case .fetching, .updates: .system("arrow.down.circle")
        case .compact: .system("arrow.down.right.and.arrow.up.left")
        case .declined: .system("hand.raised")
        case .cannotSend: .system("nosign")
        case .mac: .system("desktopcomputer")
        case .yourAnswer: .system("arrowshape.turn.up.left.fill")
        case .sendAnswer: .system("arrow.up.circle.fill")
        case .above, .floated, .earlier: .system("arrow.up")
        case .photo: .system("photo")
        case .photoLibrary: .system("photo.on.rectangle")
        case .camera: .system("camera")
        case .pickCards, .presentation: .system("rectangle.on.rectangle")
        case .expandEdit: .system("text.cursor")
        case .selectText: .system("selection.pin.in.out")
        case .dismissKeyboard: .system("keyboard.chevron.compact.down")
        case .variables: .system("curlybraces")
        case .terminal: .system("terminal")
        case .terminalWindow: .system("macwindow")
        case .readFile, .document: .system("doc.text")
        case .tool: .system("wrench.and.screwdriver")
        case .said: .system("text.bubble")
        case .started: .system("play.circle")
        case .added: .system("plus.circle")
        case .branch: .system("arrow.triangle.branch")
        case .markUnread: .system("circle.fill")
        case .fireCode: .system("flame")
        case .thinking: .system("ellipsis.bubble")
        case .researcher: .system("magnifyingglass")
        case .engineer: .system("hammer.fill")
        case .batchWorker: .system("square.stack.3d.up.fill")
        case .designer: .system("paintbrush.pointed.fill")
        case .sentinel: .system("binoculars.fill")
        case .subagent: .system("person.fill")
        case .memory: .system("brain")
        case .wakeEnabled: .system("power")
        case .wakeMessage, .talkToCue: .system("bubble.left")
        case .wakeIdle: .system("eye")
        case .wakeReminder: .system("alarm")
        case .wakeSettings: .system("arrow.left.arrow.right")
        case .mail: .system("envelope")
        case .profile: .system("face.smiling")
        case .name: .system("tag")
        case .autoApprove: .system("checkmark.shield")
        case .hotkey: .system("keyboard")
        case .appearance: .system("sun.max")
        case .testConnection: .system("antenna.radiowaves.left.and.right")
        case .web: .system("safari")
        case .markdown: .system("text.document")
        case .video: .system("film")
        case .audio: .system("waveform")
        case .pdf: .system("doc.richtext")
        case .spreadsheet: .system("tablecells")
        case .model: .system("cube")
        case .plainText: .system("doc.plaintext")
        case .project(let name): .system(name)
        }
    }

    /// 自家的墨块符号（有点睛层，按上面的着色规则画）。
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

    /// 项目图标认不认这个名字：系统里有这个符号。
    static func projectSymbolExists(_ name: String) -> Bool {
        #if os(iOS)
        UIImage(systemName: name) != nil
        #else
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
    }

    #if os(iOS)
    /// UIKit 的菜单与工具条用。
    var platformImage: UIImage? {
        switch source {
        case .ink(let name): UIImage(named: Self.ink(name))
        case .system(let name): UIImage(systemName: name)
        }
    }
    #else
    /// AppKit 的菜单与工具条用。
    var platformImage: NSImage? {
        switch source {
        case .ink(let name): NSImage(symbolName: Self.ink(name), bundle: .main, variableValue: 0)
        case .system(let name): NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
    }
    #endif

    fileprivate var image: Image {
        switch source {
        // 层级渲染：点睛是前景色的次一级。写在 Image 上，外面再设渲染方式也不覆盖它（要点亮用 `IconImage`）
        case .ink(let name): Image(Self.ink(name)).symbolRenderingMode(.hierarchical)
        case .system(let name): Image(systemName: name)
        }
    }

    /// 调色板渲染的墨块符号：主体、点睛各取外面给的一种颜色（`IconImage`）。
    fileprivate var paletteImage: Image {
        guard case .ink(let name) = source else { return image }
        return Image(Self.ink(name)).symbolRenderingMode(.palette)
    }

    private static func ink(_ name: String) -> String { "cue." + name }
}

/// `Label` 等的泛型参数也叫 Icon，扩展里用这个名字指本类型。
typealias AppIcon = Icon

extension Image {
    init(_ icon: Icon) { self = icon.image }
}

/// 点睛上色的图标（着色规则只在这里）：平时同 `Image(_:)`，点睛是前景色的次一级；`lit`（选中、正在发生）点睛靛青；
/// `state(色)` 是状态图标的点按状态色（等你赭黄…），只在那个状态存在时给。主体照外面的前景色。系统符号没有点睛，整个照前景色。
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

/// Cue 的标签图标（iPhone 底栏、iPad 侧栏与面板钮）：表情跟着 `CueMood`（`Icon.cue(_:)`），被叫醒、做完时软糖地弹一下、在最低点换表情（`Jelly`）。
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
