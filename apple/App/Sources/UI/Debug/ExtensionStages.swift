#if os(iOS) && DEBUG
import CueStore
import SwiftUI
import WidgetKit

/// 用小组件自己的视图（`WidgetViews`，主 App 也编进了它）按 iPhone 桌面的尺寸与圆角画在桌面色的底上：模拟器桌面上放小组件要点按 SpringBoard，脚本不做。
/// 小组件的容器底（`containerBackground`）只在小组件里生效，这里按同一个令牌（`desk`）画出那块底与系统的内边距。
struct DebugWidgetStage: View {
    @Environment(\.palette) private var palette

    private static let small = CGSize(width: 170, height: 170)
    private static let medium = CGSize(width: 364, height: 170)
    private static let margin: CGFloat = 16

    private static let cue = CueNowSamples.asks
    private static let home = DefaultProjectSnapshot(
        name: Project.defaultName,
        cards: [String(localized: "周末带孩子去科技馆", table: "Demo"), String(localized: "重连用例补三个", table: "Demo"), String(localized: "首页标题换成新文案", table: "Demo")].map { DefaultProjectSnapshot.Card(id: UUID(), title: $0, modifiedAt: .now) },
        total: 7)

    private var home: DefaultProjectSnapshot? {
        guard let location = DebugScene.extensionLibrary else { return Self.home }
        return Snapshots.read(DefaultProjectSnapshot.self, from: location.snapshotsDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                tile(Self.small) { WidgetViews.cue(Self.cue, family: .systemSmall) }
                tile(Self.small) { WidgetViews.defaultProject(home) }
            }
            tile(Self.medium) { WidgetViews.cue(Self.cue, family: .systemMedium) }
            tile(Self.medium) { WidgetViews.defaultProject(home) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.sidebar)
    }

    private func tile(_ size: CGSize, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(Self.margin)
            .frame(width: size.width, height: size.height)
            .background(palette.desk, in: .rect(cornerRadius: Radius.sheet))
    }
}

/// `-CuePadScene activity`：同一份视图的样式预览，不模拟状态栏与系统分区尺寸。
/// 真正宽度、长按与横屏必须用 `-CuePadLiveActivity YES` 在系统岛上验收。
struct DebugActivityStage: View {
    let workspace: Workspace
    @Environment(\.palette) private var palette
    private let stale = DebugScene.args.cueOpts.stale

    var body: some View {
        let state = CueActivityState(now: workspace.cue.now)
        let views = CueActivityViews(state, at: stale ? state.now.staleAt : .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("实时活动样式预览", tableName: "Demo").font(.headline).foregroundStyle(palette.ink)
                HStack(spacing: 120) {
                    views.compactLeading.frame(width: IslandType.countWidth)
                    views.compactTrailing
                }
                .padding(.horizontal, 9).frame(height: 37).background(.black, in: .capsule)
                views.expanded.padding(18).background(.black, in: .rect(cornerRadius: Radius.screen))
                views.lockScreen.background(palette.paper, in: .rect(cornerRadius: Radius.sheet))
                views.minimal.frame(width: 37, height: 37).background(.black, in: .circle)
            }
            .frame(maxWidth: 371).padding(20).frame(maxWidth: .infinity)
        }
        .background(palette.desk)
    }
}

/// 分享扩展的界面（`ShareViews`，主 App 也编进了它）像在分享面板里那样以表单弹出；保存不会被点，只看长相。
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
                let model = ShareModel(providers: [text, link], location: DebugScene.extensionLibrary ?? location)
                await model.load()
                self.model = model
            }
    }
}

extension DebugScene {
    static var extensionLibrary: LibraryLocation? {
        args.extensionLibrary.map { .isolated(URL(filePath: $0)) }
    }
}

#endif
