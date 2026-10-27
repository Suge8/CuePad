#if os(iOS) && DEBUG
import CueStore
import SwiftUI
import WidgetKit

/// `-CuePadScene widgets`：两种小组件（Cue、默认项目）的小号与中号，用小组件自己的视图（`WidgetViews`，主 App 也编进了它）
/// 按 iPhone 桌面的尺寸与圆角画在桌面色的底上——模拟器桌面上放小组件要点按 SpringBoard，脚本不做。
/// 小组件的容器底（`containerBackground`）只在小组件里生效，这里按同一个令牌（`desk`）画出那块底与系统的内边距。
struct DebugWidgetStage: View {
    @Environment(\.palette) private var palette

    /// iPhone 6.1～6.3 英寸屏上的桌面小组件：小号 170 × 170、中号 364 × 170，内容内边距 16（系统的 contentMargins）。
    private static let small = CGSize(width: 170, height: 170)
    private static let medium = CGSize(width: 364, height: 170)
    private static let margin: CGFloat = 16
    private static let radius: CGFloat = 23

    private static let cue = CueNowSamples.asks
    private static let home = DefaultProjectSnapshot(
        name: String(localized: "默认", table: "Demo"),
        cards: [String(localized: "周末带孩子去科技馆", table: "Demo"), String(localized: "重连用例补三个", table: "Demo"), String(localized: "首页标题换成新文案", table: "Demo")].map { DefaultProjectSnapshot.Card(id: UUID(), title: $0, modifiedAt: .now) },
        total: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                tile(Self.small) { WidgetViews.cue(Self.cue, family: .systemSmall) }
                tile(Self.small) { WidgetViews.defaultProject(Self.home) }
            }
            tile(Self.medium) { WidgetViews.cue(Self.cue, family: .systemMedium) }
            tile(Self.medium) { WidgetViews.defaultProject(Self.home) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.sidebar)
    }

    private func tile(_ size: CGSize, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(Self.margin)
            .frame(width: size.width, height: size.height)
            .background(palette.desk, in: .rect(cornerRadius: Self.radius, style: .continuous))
    }
}

/// `-CuePadScene activity`：实时活动按真实尺寸与位置画（`CueActivityViews`，主 App 也编进了它），叠在 Cue 页上：顶上紧凑态盖在灵动岛的位置，
/// 下面露出真的 Cue 页头（同一份 Cue 此刻），再往下是展开态、锁屏、最小态与横屏的窄紧凑态。画的是 Cue 那一行此刻那一份（`CueWatch.now`），
/// 配 `-CuePadCueNow <样例>`（`CueNowSamples`）钉成某一态，`-CuePadCueCycle YES` 就绪后轮流走过各态（页头与岛一起变，录切换）。
/// 系统的 `ActivityViewContext` 造不出来：过没过时（`-CuePadCueStale YES` 画过时之后的样子）、横屏窄不窄由这里给，展开态按系统的四块（左、右、摄像头下、下面）摆；岛的黑底与圆角按 iPhone 17 的量。
/// 展开态与锁屏同系统一样最高给 160 点（下半按给的高排，`ViewThatFits`），放不下的裁掉、一眼看得出。
/// 真开起来的那一个在 cue 画面配 `-CuePadDemo YES -CuePadLiveActivity YES`，回到桌面看灵动岛（`simctl io screenshot` 拍不到它，录一小段取帧）。
struct DebugActivityStage: View {
    let workspace: Workspace
    @Environment(\.palette) private var palette
    private let stale = UserDefaults.standard.bool(forKey: "CuePadCueStale")

    private static let island = Color(white: 0)
    /// 摄像头那一截宽、紧凑态高、展开态宽、锁屏卡宽（iPhone 17 竖屏，pt）。
    private static let camera: CGFloat = 120
    private static let height: CGFloat = 37
    private static let expandedWidth: CGFloat = 371
    private static let lockWidth: CGFloat = 361
    /// 展开态与锁屏最高多少（系统的上限，超出的裁掉）。
    private static let maxHeight: CGFloat = 160
    /// 露出真的页头：从屏顶到页头下沿。
    private static let header: CGFloat = 132

    var body: some View {
        let state = CueActivityState(now: workspace.cue.now, quotas: CueNowSamples.quotas)
        let views = CueActivityViews(state, at: stale ? state.now.staleAt : .now)
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: Self.header)
                palette.desk
            }
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if state.now.isLive { compact(views, limited: false) } else { Self.island.frame(width: Self.camera, height: Self.height).clipShape(.capsule) }
                }
                .frame(maxWidth: .infinity).padding(.top, 11)
                Color.clear.frame(height: Self.header - 11 - Self.height)
                if state.now.isLive {
                    label(String(localized: "长按灵动岛", table: "Demo"))
                    expanded(views)
                    label(String(localized: "锁屏", table: "Demo"))
                    views.lockScreen
                        .frame(width: Self.lockWidth)
                        .frame(maxHeight: Self.maxHeight, alignment: .top).clipped()
                        .background(palette.paper, in: .rect(cornerRadius: 22, style: .continuous))
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 0) {
                            label(String(localized: "最小（和别的实时活动同在）", table: "Demo"))
                            views.minimal.frame(width: Self.height, height: Self.height).background(Self.island, in: .circle)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            label(String(localized: "横屏（窄紧凑态）", table: "Demo"))
                            compact(views, limited: true)
                        }
                    }
                } else {
                    label(String(localized: "实时活动", table: "Demo"))
                    Text("没有在跑的活：实时活动已结束，灵动岛空出来", tableName: "Demo")
                        .font(.footnote).foregroundStyle(palette.ink3).frame(width: Self.lockWidth, height: 56)
                        .background(palette.fill, in: .rect(cornerRadius: 22, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            // 时间只在岛收着时写：岛撑开时真机上系统让开状态栏，这里照写就会压在紧凑态左半上（头像右下多出的"1"）
            if !state.now.isLive {
                HStack {
                    Text("9:41").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.ink).frame(width: 78)
                    Spacer()
                }
                .padding(.top, 21).padding(.horizontal, 6)
            }
        }
        .ignoresSafeArea()
        // 系统的状态栏画在最上层、会压住岛的两端：藏起来，岛收着时自己写时间
        .statusBarHidden(true)
        .animation(Motion.travel, value: workspace.cue.now)
        .allowsHitTesting(false)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(palette.ink3).padding(.top, 14).padding(.bottom, 6)
    }

    /// 紧凑态：系统按摄像头左右对称地撑开，两边一样宽（取宽的那边，同系统），摄像头在正中。
    private func compact(_ views: CueActivityViews, limited: Bool) -> some View {
        SymmetricSides(gap: limited ? 14 : Self.camera, least: limited ? 0 : 66) {
            views.compactLeading(limited: limited).fixedSize()
            views.compactTrailing(limited: limited).fixedSize()
        }
        .padding(.horizontal, 9)
        .frame(height: Self.height)
        .background(Self.island, in: .capsule)
    }

    /// 展开态：左右两块贴着摄像头两侧，摄像头下是中间那块，再下面是下面那块。
    private func expanded(_ views: CueActivityViews) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                views.expandedLeading
                VStack(spacing: 0) {
                    Color.clear.frame(height: 26)
                    views.expandedCenter
                }
                views.expandedTrailing
            }
            views.expandedBottom
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 16)
        .frame(width: Self.expandedWidth)
        .frame(maxHeight: Self.maxHeight, alignment: .top).clipped()
        .background(Self.island, in: .rect(cornerRadius: 44, style: .continuous))
    }
}

/// `-CuePadScene share`：分享扩展的界面（`ShareViews`，主 App 也编进了它）像在分享面板里那样以表单弹出，
/// 内容是一段文字与一个链接（扩展从系统拿到的 `NSItemProvider` 同样的两种）。保存不会被点：只看长相。
struct DebugShareStage: View {
    let location: LibraryLocation
    @State private var model: ShareModel?
    @Environment(\.palette) private var palette

    var body: some View {
        palette.desk
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                if let model { ShareViews.root(model, dismiss: {}, cancel: {}) }
            }
            .task {
                let text = NSItemProvider(object: String(localized: "周末带孩子去科技馆，记得提前约票", table: "Demo") as NSString)
                let link = NSItemProvider(object: URL(string: "https://example.com/museum")! as NSURL)
                let model = ShareModel(providers: [text, link], location: location)
                await model.load()
                self.model = model
            }
    }
}

/// 紧凑态的两半：左右一样宽（取宽的那边、至少 `least`），中间隔着摄像头那一截；左边那半贴左、右边那半贴右。
private struct SymmetricSides: Layout {
    let gap: CGFloat
    let least: CGFloat

    private func side(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(least, max)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: side(subviews) * 2 + gap, height: subviews.map { $0.sizeThatFits(.unspecified).height }.reduce(0, max))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}
#endif
