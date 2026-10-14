import CueStore
#if os(macOS)
import Quartz
#else
import QuickLook
#endif
import SwiftUI

/// 附件目录里的文件在本机的可读位置：文件以哈希为名，没有扩展名，系统的快速查看与"存到文件"认不出类型，
/// 所以按文件名放一份（缓存目录里，同卷克隆不占额外空间，系统可随时清理）。预览文件与对话里的图片共用。
nonisolated enum PreviewFile {
    static func url(hash: String, name: String, original: URL) -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "CuePadPreviews", directoryHint: .isDirectory).appending(path: hash, directoryHint: .isDirectory)
        // 文件名来自同步的记录：不能带路径
        let target = directory.appending(path: name.replacing("/", with: "_").replacing("..", with: "_"))
        guard !FileManager.default.fileExists(atPath: target.path) else { return target }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: target)
            return target
        } catch {
            return nil
        }
    }
}

/// 点开的那一个文件，和与它同一批（同一张卡）的几个：在全屏页里左右切换。
struct PreviewOpening: Identifiable, Equatable {
    let preview: PiPreview
    let batch: [PiPreview]

    init(preview: PiPreview, batch: [PiPreview]? = nil) {
        self.preview = preview
        self.batch = batch ?? [preview]
    }

    var id: UUID { preview.id }
}

extension View {
    /// 点预览卡后的全屏页：一批里的几个在同一页里左右切换（前后箭头：Mac 在右上角，手机在底栏；手机上网页与 Markdown 那几页也能左右滑）。网页与 Markdown 由 CuePad 自己显示
    /// （网页只读、不联网），其余嵌系统的快速查看（缩放、播放、翻页都有）。一个对话只在这里挂一次，不在每张卡上各挂一个。
    func previewPresenter(_ opened: Binding<PreviewOpening?>) -> some View { modifier(PreviewPresenter(opened: opened)) }
}

private struct PreviewPresenter: ViewModifier {
    @Binding var opened: PreviewOpening?
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .panel(item: $opened, style: .fullScreen) {
                PreviewPager(batch: $0.batch, current: $0.preview.id)
                    #if os(macOS)
                    .frame(maxWidth: 960, maxHeight: 720)
                    .background(palette.desk)
                    #endif
            }
    }
}

/// 全屏页：顶上是各端浮层统一的那一行（Mac 是 `PanelHeader`：标题居中，前后箭头、分享与关闭在右上；iOS 是系统顶栏：左关闭、右分享），
/// 标题是当前这个文件（一批共用一个标题时写文件名，同卡片上的写法），不另画分隔线，内容紧接着铺满。
private struct PreviewPager: View {
    let batch: [PiPreview]
    @State var current: UUID
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.closePanel) private var close
    #endif

    private var index: Int { batch.firstIndex { $0.id == current } ?? 0 }
    private var preview: PiPreview { batch[index] }
    private var title: String { PreviewGroup.label(of: preview, in: batch) }
    /// 一批里第几个，只有一个时不写
    private var position: String? { batch.count > 1 ? "\(index + 1) / \(batch.count)" : nil }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            TabView(selection: $current) {
                ForEach(batch) { PreviewContent(preview: $0, file: file(of: $0), active: $0.id == current).tag($0.id) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(palette.desk)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { close() } }
                if let file = file(of: preview) { ToolbarItem(placement: .primaryAction) { ShareLink(item: file) } }
                // 快速查看自己吃掉左右滑（它里面也是一个翻页的滚动区），翻到它那页时只能靠这两个箭头
                if let position {
                    ToolbarItemGroup(placement: .bottomBar) {
                        stepper(position)
                    }
                }
            }
        }
        #else
        VStack(spacing: 10) {
            PanelHeader(title: title) {
                if let position { stepper(position) }
                if let file = file(of: preview) {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up").accessibilityLabel("分享") }
                }
            }
            .buttonStyle(.borderless).foregroundStyle(palette.ink2)
            PreviewContent(preview: preview, file: file(of: preview)).id(preview.id)
        }
        .padding(.top, 14)
        .background(palette.desk)
        #endif
    }

    /// 前后箭头夹着"第几个 / 共几个"。
    @ViewBuilder private func stepper(_ position: String) -> some View {
        Button("上一个", systemImage: "chevron.left") { step(-1) }.labelStyle(.iconOnly).disabled(index == 0)
        Text(position).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
        Button("下一个", systemImage: "chevron.right") { step(1) }.labelStyle(.iconOnly).disabled(index == batch.count - 1)
    }

    private func step(_ offset: Int) {
        withAnimation(Motion.quick) { current = batch[index + offset].id }
    }

    private func file(of preview: PiPreview) -> URL? {
        services.store.files.fileURL(for: preview.hash).flatMap { PreviewFile.url(hash: preview.hash, name: preview.systemFileName, original: $0) }
    }
}

/// 一个文件的内容：网页、Markdown 自己显示，其余嵌快速查看。
private struct PreviewContent: View {
    let preview: PiPreview
    let file: URL?
    /// 是不是翻到的这一页（翻页留着的邻页不是）
    var active = true
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let file {
                switch preview.kind {
                case .web: PreviewWeb(file: file)
                case .markdown: PreviewMarkdown(file: file)
                #if os(macOS)
                default: QuickLookPage(file: file)
                #else
                default: QuickLookPage(file: file, active: active)
                #endif
                }
            } else {
                EmptyState(mascot: .error, title: "读不了这个文件").padding(24).frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk)
    }
}

#if os(macOS)
/// 嵌在页里的快速查看。音视频翻到就播（同系统的快速查看面板；视频的播放控件要指针移上去才出现）；拆掉时关掉它，正在播的随之停下。
private struct QuickLookPage: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.autostarts = true
        view.previewItem = file as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != file { view.previewItem = file as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
#else
/// 嵌在页里的快速查看（只放这一个文件，切换由外面的分页做）。快速查看在另一个进程里播音视频，控制器拆掉或翻走了它还接着播：
/// 不在当前页时换成空列表让它停下，翻回来再放回这个文件。
private struct QuickLookPage: UIViewControllerRepresentable {
    let file: URL
    var active = true

    func makeCoordinator() -> Source { Source() }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        context.coordinator.file = active ? file : nil
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        let shown = active ? file : nil
        guard context.coordinator.file != shown else { return }
        context.coordinator.file = shown
        controller.reloadData()
    }

    final class Source: NSObject, QLPreviewControllerDataSource {
        var file: URL?
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { file == nil ? 0 : 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { file! as NSURL }
    }
}
#endif

private struct PreviewMarkdown: View {
    let file: URL
    @State private var text: String?
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            MarkdownText(source: text ?? "").padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task { text = (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    }
}
