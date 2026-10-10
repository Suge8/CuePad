#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 会话页要放在窗口工具栏上的东西：标题（会话名接"状态 · 计时"）与"⋯"（所在、重命名、跳到终端、结束会话）。
/// 工具栏项在主窗口里常驻（`SessionTitleSlot`、`SessionMenuSlot`），随页面切换换里面的内容：增删工具栏项会重建整条工具栏，
/// 进出会话页、换会话时那要占点击回合的一半。会话页只把算好的值与动作交到这里；不是会话页时槽里是空的。
@MainActor @Observable
final class SessionHeader {
    struct State: Equatable {
        var session: PiSessionState
        var title: String
        var undelivered: String?
        var ending: Bool
        /// "⋯"最上面写的所在。
        var place: Dotted?
        /// 本机桥上在线、开在终端里的会话（可跳到终端）。
        var liveID: CuePi.PiSession.ID?
        var canEnd: Bool
        var canRename: Bool
        /// 对话在看历史时标题让开。
        var showsHeader: Bool
    }

    private(set) var state: State?
    @ObservationIgnored var rename: (PiSessionState) -> Void = { _ in }
    @ObservationIgnored var end: () -> Void = {}
    @ObservationIgnored var reveal: () -> Void = {}

    func set(_ state: State?) {
        if self.state != state { self.state = state }
    }

    /// 离开的会话页只清自己的：换会话时新页面的值可能已经先到了。
    func clear(_ sessionID: String) {
        if state?.session.sessionID == sessionID { state = nil }
    }
}

extension Workspace {
    /// 当前会话页的标题与菜单要显示的值；不是会话页时为 nil。
    var shownSessionHeader: SessionHeader.State? {
        guard case .session(let id) = page, let state = sessionHeader.state, state.session.sessionID == id else { return nil }
        return state
    }
}

/// 工具栏标题位：一块玻璃里一行，会话名接"状态 · 计时"（所在写在"⋯"菜单最上面；工具栏的玻璃只有一行高）。
/// 玻璃画在标题自己身上、随它一起淡出：系统给工具栏项画的那块不随内容显隐，让开时会留下一块空玻璃。
struct SessionTitleSlot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    /// 点标题弹出的说明（需要 /reload 时）开着。
    @State private var explaining = false

    /// 工具栏里标题一块最宽多少：名字长时截断，不把右边的按钮挤走。
    private static let width: CGFloat = 420

    var body: some View {
        if let state = workspace.shownSessionHeader {
            title(state)
        }
    }

    private func title(_ state: SessionHeader.State) -> some View {
        let session = state.session
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(state.title).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            if state.ending {
                Text("正在结束…").font(Typography.toolbarSubtitle).foregroundStyle(palette.ink3)
            } else {
                // 副标题以状态标打头：图形没有文字基线，按它的底边对齐会把整行压低；对齐到行里文字的基线
                PiSessionSubtitle(session: session, undelivered: state.undelivered)
                    .alignmentGuide(.firstTextBaseline) { $0[.lastTextBaseline] }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: Self.width, alignment: .leading)
        .frame(height: Spacing.toolbarControl)
        .glass(in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        // 需要 /reload 的会话：状态就写在这块玻璃里，点它看怎么接上（不在对话上另浮一张卡）
        .contentShape(.rect)
        .onTapGesture { if state.showsHeader, PiShown(session).explanation != nil { explaining = true } }
        .explanationPopover(PiShown(session).explanation, isPresented: $explaining)
        .opacity(state.showsHeader ? 1 : 0)
        .animation(Motion.quick, value: state.showsHeader)
        .allowsHitTesting(state.showsHeader)
        .accessibilityHidden(!state.showsHeader)
        // 让开时这一块仍接指针：移上去或点一下唤出
        .background {
            if !state.showsHeader {
                Color.clear.contentShape(.rect)
                    .onHover { if $0 { workspace.sessionHeader.reveal() } }
                    .onTapGesture { workspace.sessionHeader.reveal() }
            }
        }
    }
}

/// 工具栏右边的"⋯"：最上面写所在，下面重命名、跳到终端（开在终端里的在线会话）、结束会话；都没有时不出现。
struct SessionMenuSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let state = workspace.shownSessionHeader, state.place != nil || state.canRename || state.liveID != nil || state.canEnd {
            Menu("更多", systemImage: "ellipsis") {
                if let place = state.place { Section { } header: { Text(place) } }
                if state.canRename {
                    Button("重命名…", systemImage: "pencil") { workspace.sessionHeader.rename(state.session) }
                }
                if let id = state.liveID {
                    Button("跳到终端窗口", systemImage: "macwindow") { workspace.jumpToTerminal(id) }
                }
                if state.canEnd {
                    Button("结束会话", systemImage: "stop.circle", role: .destructive) { workspace.sessionHeader.end() }
                        .disabled(state.ending)
                }
            }
            .menuIndicator(.hidden)
            .help("重命名、跳到终端、结束会话")
        }
    }
}
#endif
