import CueStore
import QuickLook
import SwiftUI

/// 预览文件在本机的可读位置：附件目录里的文件以哈希为名，没有扩展名，系统的快速查看与"存到文件"认不出类型，
/// 所以按原文件名放一份（缓存目录里，同卷克隆不占额外空间，系统可随时清理）。
nonisolated enum PreviewFile {
    static func url(for preview: PiPreview, original: URL) -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "CuePadPreviews", directoryHint: .isDirectory).appending(path: preview.hash, directoryHint: .isDirectory)
        // 记录来自同步：文件名不能带路径
        let target = directory.appending(path: preview.name.replacing("/", with: "_").replacing("..", with: "_"))
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

extension View {
    /// 点预览卡后的全屏预览：网页与 Markdown 在 CuePad 自己的页里（网页只读、不联网），图片、PDF、文本交给系统的快速查看（缩放、翻页、分享都有）。
    /// 一个对话只在这里挂一次，不在每张卡上各挂一个。
    func previewPresenter(_ opened: Binding<PiPreview?>) -> some View { modifier(PreviewPresenter(opened: opened)) }
}

private struct PreviewPresenter: ViewModifier {
    @Binding var opened: PiPreview?
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var quickLook: URL?

    private var own: Binding<PiPreview?> {
        Binding { opened.flatMap { $0.kind == .web || $0.kind == .markdown ? $0 : nil } } set: { opened = $0 }
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
            .quickLookPreview($quickLook)
            .onChange(of: opened) { _, preview in
                guard let preview, own.wrappedValue == nil else { return }
                quickLook = file(of: preview)
                opened = nil
            }
    }

    private func file(of preview: PiPreview) -> URL? {
        services.store.files.fileURL(for: preview.hash).flatMap { PreviewFile.url(for: preview, original: $0) }
    }
}

/// 网页与 Markdown 的全屏页：一条顶栏（关闭、标题、分享到文件），下面是内容。
private struct PreviewPage: View {
    let preview: PiPreview
    let file: URL?
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("关闭") { close() }
                Text(preview.title).font(Typography.bodyStrong).foregroundStyle(palette.ink).lineLimit(1).frame(maxWidth: .infinity)
                if let file { ShareLink(item: file) { Image(systemName: "square.and.arrow.up").accessibilityLabel("分享") } } else { Color.clear.frame(width: 24) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
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
