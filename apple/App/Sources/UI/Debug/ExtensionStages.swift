#if os(iOS) && DEBUG
import CueStore
import SwiftUI
import UIKit
import WidgetKit

/// `-CuePadScene widgets`：两种小组件（Cue、未分类）的小号与中号，用小组件自己的视图（`WidgetViews`，主 App 也编进了它）
/// 按 iPhone 桌面的尺寸与圆角画在桌面色的底上——模拟器桌面上放小组件要点按 SpringBoard，脚本不做。
/// 小组件的容器底（`containerBackground`）只在小组件里生效，这里按同一个令牌（`desk`）画出那块底与系统的内边距。
struct DebugWidgetStage: View {
    @Environment(\.palette) private var palette

    /// iPhone 6.1～6.3 英寸屏上的桌面小组件：小号 170 × 170、中号 364 × 170，内容内边距 16（系统的 contentMargins）。
    private static let small = CGSize(width: 170, height: 170)
    private static let medium = CGSize(width: 364, height: 170)
    private static let margin: CGFloat = 16
    private static let radius: CGFloat = 23

    private static let cue = CueSnapshot(name: "Cue", managing: 3, waiting: 2, mood: "waiting")
    private static let unfiled = UnfiledSnapshot(
        cards: ["周末带孩子去科技馆", "重连用例补三个", "首页标题换成新文案"].map { UnfiledSnapshot.Card(id: UUID(), title: $0, modifiedAt: .now) },
        total: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                tile(Self.small) { WidgetViews.cue(Self.cue, family: .systemSmall) }
                tile(Self.small) { WidgetViews.unfiled(Self.unfiled) }
            }
            tile(Self.medium) { WidgetViews.cue(Self.cue, family: .systemMedium) }
            tile(Self.medium) { WidgetViews.unfiled(Self.unfiled) }
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

/// `-CuePadScene activity`：实时活动的各态（`CueActivityViews`，主 App 也编进了它）按真实尺寸画在桌面色的底上——锁屏卡（新的与过时的）、
/// 灵动岛的紧凑态（有等你、只有在管）、最小态与展开态。系统的 `ActivityViewContext` 造不出来，过没过时由这里给；岛的黑底与圆角按 iPhone 17 的量。
/// 真开起来的那一个在 cue 画面配 `-CuePadDemo YES`：演示库里有在管与等你，App 在前台就开（`CueLiveActivity`），回到桌面看灵动岛。
struct DebugActivityStage: View {
    @Environment(\.palette) private var palette

    private static let island = Color(white: 0)
    /// 紧凑态整条宽 × 高、展开态宽（iPhone 17 竖屏，pt）。
    private static let compact = CGSize(width: 250, height: 37)
    private static let expandedWidth: CGFloat = 371
    private static let lockWidth: CGFloat = 361

    private static let first = CueActivityState.Wait(
        title: "发布 v1.4 到 TestFlight", detail: "Cue 请你允许发布或部署", open: DeepLink.cue.url,
        allow: CueActivityState.Allow(message: UUID(), choice: CueAsk.once))
    private static let busy = CueActivityState(
        mood: "waiting", managing: 3, waiting: 2, done: 1, first: first,
        lastDone: CueActivityState.Done(title: "README 截图换成 Swift 版", at: .now.addingTimeInterval(-6 * 60)), at: .now)
    private static let managingOnly = CueActivityState(mood: "thinking", managing: 3, waiting: 0, done: 2, first: nil, lastDone: nil, at: .now)
    private static let asked = CueActivityState(
        mood: "waiting", managing: 1, waiting: 1, done: 0,
        first: CueActivityState.Wait(title: "rename", detail: "要把 utils 拆成两个文件吗？", open: DeepLink.cue.url, allow: nil),
        lastDone: nil, at: .now.addingTimeInterval(-23 * 60))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                label("锁屏")
                lock(Self.busy, stale: false)
                label("锁屏 · 会话在问、过时")
                lock(Self.asked, stale: true)
                label("紧凑态 · 有等你 / 只有在管")
                compact(Self.busy)
                compact(Self.managingOnly)
                label("最小态")
                CueActivityViews.minimal(Self.busy).frame(width: Self.compact.height, height: Self.compact.height).background(Self.island, in: .circle)
                label("展开态")
                expanded(Self.busy)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(palette.sidebar)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
    }

    private func lock(_ state: CueActivityState, stale: Bool) -> some View {
        CueActivityViews.lockScreen(state, stale: stale)
            .frame(width: Self.lockWidth)
            .background(palette.paper, in: .rect(cornerRadius: 22, style: .continuous))
    }

    private func compact(_ state: CueActivityState) -> some View {
        HStack {
            CueActivityViews.compactLeading(state)
            Spacer()
            CueActivityViews.compactTrailing(state)
        }
        .padding(.horizontal, 7)
        .frame(width: Self.compact.width, height: Self.compact.height)
        .background(Self.island, in: .capsule)
    }

    private func expanded(_ state: CueActivityState) -> some View {
        VStack(spacing: 8) {
            HStack {
                CueActivityViews.expandedLeading(state)
                Spacer()
                CueActivityViews.expandedTrailing(state)
            }
            CueActivityViews.expandedBottom(state, stale: false)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 18)
        .frame(width: Self.expandedWidth)
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
                let text = NSItemProvider(object: "周末带孩子去科技馆，记得提前约票" as NSString)
                let link = NSItemProvider(object: URL(string: "https://example.com/museum")! as NSURL)
                let model = ShareModel(providers: [text, link], location: location)
                await model.load()
                self.model = model
            }
    }
}
#endif
