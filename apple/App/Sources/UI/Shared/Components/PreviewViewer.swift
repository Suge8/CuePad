import CueStore
import QuickLook
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

/// 点开的那一个文件，和与它同一批（同一张卡）的几个：快速查看里左右切换。
struct PreviewOpening: Equatable {
    let preview: PiPreview
    let batch: [PiPreview]

    init(preview: PiPreview, batch: [PiPreview]? = nil) {
        self.preview = preview
        self.batch = batch ?? [preview]
    }
}

extension View {
    /// 点预览卡后的全屏预览：网页与 Markdown 在 CuePad 自己的页里（网页只读、不联网），其余交给系统的快速查看（缩放、播放、翻页、分享都有），
    /// 同一批里交给快速查看的几个在里面左右切换。一个对话只在这里挂一次，不在每张卡上各挂一个。
    func previewPresenter(_ opened: Binding<PreviewOpening?>) -> some View { modifier(PreviewPresenter(opened: opened)) }
}

private struct PreviewPresenter: ViewModifier {
    @Binding var opened: PreviewOpening?
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var quickLook: URL?
    @State private var quickLookBatch: [URL] = []

    private var own: Binding<PiPreview?> {
        Binding { opened.flatMap { $0.preview.opensInQuickLook ? nil : $0.preview } } set: { if $0 == nil { opened = nil } }
    }

    func body(content: Content) -> some View {
        content
            .panel(item: own, style: .fullScreen) {
                PreviewPage(preview: $0, file: file(of: $0))
                    #if os(macOS)
                    .frame(maxWidth: 960, maxHeight: 720)
                    .background(palette.desk)
                    #endif
            }
            .quickLookPreview($quickLook, in: quickLookBatch)
            .onChange(of: opened) { _, opening in
                guard let opening, opening.preview.opensInQuickLook else { return }
                quickLookBatch = opening.batch.filter(\.opensInQuickLook).compactMap(file(of:))
                quickLook = file(of: opening.preview)
                opened = nil
            }
    }

    private func file(of preview: PiPreview) -> URL? {
        services.store.files.fileURL(for: preview.hash).flatMap { PreviewFile.url(hash: preview.hash, name: preview.systemFileName, original: $0) }
    }
}

/// 网页与 Markdown 的全屏页：顶上是各端浮层统一的那一行（Mac 是 `PanelHeader`：标题居中、分享与关闭在右上；iOS 是系统顶栏：左关闭、右分享），
/// 不另画分隔线，内容紧接着铺满。
private struct PreviewPage: View {
    let preview: PiPreview
    let file: URL?
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.closePanel) private var close
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            page
                .navigationTitle(preview.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { close() } }
                    if let file { ToolbarItem(placement: .primaryAction) { ShareLink(item: file) } }
                }
        }
        #else
        VStack(spacing: 10) {
            PanelHeader(title: preview.title) {
                if let file {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up").accessibilityLabel("分享") }
                        .buttonStyle(.borderless).foregroundStyle(palette.ink2)
                }
            }
            page
        }
        .padding(.top, 14)
        .background(palette.desk)
        #endif
    }

    @ViewBuilder private var page: some View {
        Group {
            if let file {
                switch preview.kind {
                case .markdown: PreviewMarkdown(file: file)
                default: PreviewWeb(file: file)
                }
            } else {
                EmptyState(mascot: .error, title: "读不了这个文件").padding(24).frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk)
    }
}

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
