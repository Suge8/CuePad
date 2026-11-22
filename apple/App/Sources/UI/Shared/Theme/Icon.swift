import CueEditor
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 全 App 的图标，按意思取名，全是自家的圆润轮廓符号（cue.*，由 design/tools/cue-symbols.py 生成）；哪个意思画成哪个符号只在 `source` 一处写。
/// 别处不写符号名，全 App 不用系统符号（lint 拦）：界面用 `Image(_:)`、`Label(_:icon:)`、`Button(_:icon:)`、`Menu(_:icon:)`，
/// UIKit、AppKit 的菜单与工具条用 `platformImage`。品牌标志（`BrandMark`）不在这里；项目图标走 `project`（闭合表 `ProjectIcon`）。
/// 图标是装饰图：按名字取的图读屏念资源名（"cue.plus"），意思由所在控件的标签说——只画图标的按钮写 `accessibilityLabel`，只靠图标表意的记号用 `iconLabel`。
/// iOS 上装饰图照样是一个没有名字的"图像"让旁白停下（模拟器旁白实测）：不在按钮、`Label`、合并元素里的图标挂 `readerHidden(true)`。`Label` 里的图标照名字取（`labelImage`）：只画图标的标签（`.iconOnly`）把字挂到图标上当读屏标签，装饰图挂不上，按钮就没了名字。
///
/// 着色（功能图标主体为单层等宽轮廓，Cue 品牌保留点睛层，见 design/tools/cue-symbols.py）：
/// - 平时点睛是这一处前景色的次一级（层级渲染：墨色前景时就是次墨），不用另上色；单色场合（系统菜单、工具栏）照系统。
/// - 反白符号（`filled`）不按层着色，调用方给两种颜色时按层上色。
nonisolated enum Icon: Hashable, Sendable {
    case cue
    case idea, task, session, search, settings, archive, trash, sidebar
    case rightColumn
    case agent, all, filter, extensionNote
    case skill, instruction
    case waiting, failure, undelivered, onTheWay, replied, fresh, ended, interrupted, unknown, gone
    case compacting
    case done, donePending, picked
    case syncStarting, synced, syncing, syncOff, syncRestricted, syncTrouble, syncPaused, uploadLocal, replaceWithCloud, syncNow
    case alertsPending, alertsOn, alertsOff
    case complete, reopen, restore, undo, start, add, indent, outdent, link, unlink
    case projects, folder, unbindFolder, pin, unpin, emptyTrash
    case copy, share, saveAsIdea, write, rename, close, remove, clear, more
    case forward, back, expand, collapse, choose, conflict
    case help, duplicate
    case send, save, checked, stop, endSession, wakeSession, handOff, delivered, retry, toLatest, fetching, renew
    case cold, warm
    case declined, mac, yourAnswer, above, floated, earlier, recent
    case reply, remoteMac
    case livePreview, phoneWidth, openInBrowser, pickElement, enlarge, shrink
    case call, microphone, muted
    case fast
    case attachment
    case photo, photoLibrary, camera, pickCards, expandEdit, selectText, variables
    case terminal, readFile, editFile, pondering, tool, said, started, added, branch, markUnread, fireCode, thinking
    case relay, relayStalled
    case memory, wakeEnabled, wakeMessage, wakeActivity, wakeIdle, schedule, looked
    case name, voice, sounds, hotkey, talkToCue, appearance, language, updates, launchAtLogin
    case audio, document, downloading, play, file, inspect3D
    case project(ProjectIcon)

    private enum Source {
        case ink(String)
        case filled(String)
    }

    private var source: Source {
        switch self {
        case .cue: .ink("mascot")
        case .idea: .ink("idea")
        case .task: .ink("task")
        case .session, .pondering: .ink("session")
        case .search: .ink("search")
        case .settings: .ink("settings")
        case .language: .ink("globe")
        case .archive: .ink("archive")
        case .trash: .ink("trash")
        case .sidebar: .ink("sidebar")
        case .rightColumn: .ink("sidebar.right")
        case .add: .ink("plus")
        case .close, .remove: .ink("close")
        case .clear: .ink("clear")
        case .emptyTrash: .ink("sweep")
        case .more: .ink("more")
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
        case .failure: .ink("failure")
        case .undelivered: .ink("undelivered")
        case .replied: .ink("mail")
        case .alertsPending: .ink("bell")
        case .fresh: .ink("sparkle")
        case .ended: .ink("ended")
        case .gone: .ink("gone")
        case .compacting: .ink("spring")
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
        case .reopen, .undo: .ink("reopen")
        case .restore: .ink("restore")
        case .recent: .ink("clock")
        case .start, .play: .ink("play")
        case .indent: .ink("indent")
        case .outdent: .ink("outdent")
        case .link: .ink("link")
        case .unlink: .ink("unlink")
        case .folder, .projects: .ink("folder")
        case .unbindFolder: .ink("folder.remove")
        case .pin: .ink("pin")
        case .unpin: .ink("unpin")
        case .copy: .ink("copy")
        case .conflict, .duplicate: .ink("conflict")
        case .help: .ink("question")
        case .share: .ink("share")
        case .saveAsIdea: .ink("save")
        case .write: .ink("write")
        case .rename, .editFile: .ink("pencil")
        case .choose: .ink("choose")
        case .all: .ink("deck")
        case .filter: .ink("filter")
        case .extensionNote: .ink("puzzle")
        case .skill: .ink("skill")
        case .instruction: .ink("doc")

        case .save, .checked: .ink("tick")
        case .endSession: .ink("ring.stop")
        case .handOff: .ink("plane")
        case .delivered: .ink("plane.done")
        case .retry: .ink("reload")
        case .toLatest: .ink("arrow.down")
        case .fetching: .ink("ring.down")
        case .cold: .ink("cold")
        case .warm: .ink("clock")
        case .declined: .ink("hand")
        case .mac: .ink("mac")
        case .yourAnswer: .ink("restore")
        case .above, .floated, .earlier: .ink("arrow.up")
        case .attachment: .ink("clip")
        case .photo: .ink("photo")
        case .photoLibrary: .ink("photos")
        case .camera: .ink("camera")
        case .pickCards: .ink("conflict")
        case .expandEdit: .ink("cursor")
        case .selectText: .ink("select")
        case .variables: .ink("braces")
        case .terminal: .ink("terminal")
        case .readFile: .ink("doc")
        case .tool: .ink("wrench")
        case .said, .reply: .ink("bubble.text")
        case .remoteMac: .ink("mac")
        case .livePreview: .ink("window.play")
        case .phoneWidth: .ink("phone")
        case .openInBrowser: .ink("external")
        case .pickElement: .ink("pointer")
        case .enlarge: .ink("enlarge")
        case .shrink: .ink("shrink")
        case .started: .ink("ring.play")
        case .added: .ink("ring.plus")
        case .branch: .ink("branch")
        case .markUnread: .ink("dot")
        case .fireCode: .ink("flame")
        case .thinking: .ink("bubble.dots")
        case .relay: .ink("relay")
        case .relayStalled: .ink("relay.stalled")
        case .memory: .ink("bookmark")
        case .wakeEnabled, .launchAtLogin, .wakeSession: .ink("power")
        case .wakeActivity, .fast: .ink("bolt")
        case .wakeMessage, .talkToCue: .ink("bubble")
        case .wakeIdle, .looked: .ink("eye")
        case .schedule: .ink("alarm")
        case .name: .ink("tag")
        case .hotkey: .ink("keyboard")
        case .appearance: .ink("sun")
        case .updates: .ink("badge.down")
        case .audio, .call, .voice: .ink("wave")
        case .microphone: .ink("mic")
        case .sounds: .ink("speaker")
        case .muted: .ink("mic.off")
        case .document: .ink("doc")
        case .downloading: .ink("cloud.down")
        case .file: .ink("doc.blank")
        case .inspect3D: .ink("cube")
        case .project(let icon): .ink(icon.symbol)
        }
    }

    #if os(iOS)
    var platformImage: UIImage? {
        switch source {
        case .ink(let name), .filled(let name): UIImage(named: Self.ink(name))
        }
    }
    #else
    var platformImage: NSImage? {
        switch source {
        case .ink(let name), .filled(let name): NSImage(symbolName: Self.ink(name), bundle: .main, variableValue: 0)
        }
    }
    #endif

    fileprivate var labelImage: Image {
        switch source {
        case .ink(let name): Image(Self.ink(name)).symbolRenderingMode(.hierarchical)
        case .filled(let name): Image(Self.ink(name))
        }
    }

    fileprivate var image: Image {
        switch source {
        // 层级渲染：点睛是前景色的次一级。写在 Image 上，外面再设渲染方式也不覆盖它
        case .ink(let name): Image(decorative: Self.ink(name)).symbolRenderingMode(.hierarchical)
        case .filled(let name): Image(decorative: Self.ink(name))
        }
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

typealias AppIcon = Icon

extension Image {
    init(_ icon: Icon) { self = icon.image }
}

extension View {
    /// 只靠图标表意、旁边没有字说它的（卡上的图钉、格式不对的叉）：图标是装饰图，直接挂标签不进读屏，这里把它收成一个带标签的图。
    func iconLabel(_ label: Text) -> some View {
        accessibilityElement().accessibilityLabel(label).accessibilityAddTraits(.isImage)
    }

    func iconLabel(_ label: LocalizedStringResource) -> some View { iconLabel(Text(label)) }

    @_disfavoredOverload
    func iconLabel(_ label: some StringProtocol) -> some View { iconLabel(Text(label)) }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: LocalizedStringResource, icon: AppIcon) {
        self.init { Text(title) } icon: { icon.labelImage }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, icon: AppIcon) {
        self.init { Text(title) } icon: { icon.labelImage }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringResource, icon: AppIcon, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, icon: AppIcon, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringResource, icon: AppIcon, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, icon: icon) }
    }

    @_disfavoredOverload
    init(_ title: some StringProtocol, icon: AppIcon, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, icon: icon) }
    }
}

extension Toggle where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringResource, icon: AppIcon, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { SwiftUI.Label(title, icon: icon) }
    }
}

extension CueSelectionAction {
    init(title: String, icon: Icon, perform: @escaping @MainActor (String) -> Void) {
        self.init(title: title, image: icon.platformImage, perform: perform)
    }
}
