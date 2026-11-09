import CueText
import SwiftUI

/// 调用方先解析整篇块结构，附件切分不能重启列表或围栏。
nonisolated enum MarkdownMedia {
    enum Part { case text(AttributedString), image(String, String), file(key: String, name: String) }

    static func parts(_ source: String) -> [Part] {
        CueFormat.parse(source).flatMap { token -> [Part] in
            switch token {
            case .text(let text): inlineParts(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .image(let key): [.image(key, "")]
            case .file(let key, let name): [.file(key: key, name: name)]
            }
        }
    }

    private static func inlineParts(_ source: String) -> [Part] {
        let text = AttributedString(inlineMarkdown: source)
        var parts: [Part] = []
        var pending = AttributedString()
        for run in text.runs {
            let fragment = AttributedString(text[run.range])
            if let url = run.imageURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                if !pending.characters.isEmpty { parts.append(.text(pending)); pending = AttributedString() }
                parts.append(.image(url.absoluteString, String(fragment.characters).replacingOccurrences(of: "\u{FFFC}", with: "")))
            } else { pending.append(fragment) }
        }
        if !pending.characters.isEmpty { parts.append(.text(pending)) }
        return parts
    }

    static func imageKeys(in source: String) -> [String] {
        var keys: [String] = []
        for block in MarkdownBlock.parse(source) {
            let texts: [String]
            switch block.content {
            case .paragraph(let text), .heading(_, let text), .quote(let text): texts = [text]
            case .table(let table): texts = table.header + table.rows.flatMap { $0 }
            case .code, .rule: texts = []
            }
            for text in texts {
                for case .image(let key, _) in parts(text) where !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }
}

struct MarkdownMediaView: View {
    let source: String
    var images: [String: CGImage] = [:]
    var exporting = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            ForEach(Array(MarkdownMedia.parts(source).enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text): MarkdownInlineText(text: MarkdownText.styledInline(text, palette))
                case .image(let key, let alt):
                    if let image = images[key] {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .accessibilityLabel(alt)
                    } else if !exporting {
                        if let url = URL(string: key), url.scheme != nil { RemoteMarkdownImage(url: url, alt: alt) }
                        else { InspirationImage(key: key) }
                    }
                case .file(let key, let name):
                    if exporting { Label(name, icon: .attachment).font(Typography.secondary).foregroundStyle(palette.ink2) }
                    else { InspirationFile(file: DraftFile(key: key, name: name)) }
                }
            }
        }
    }
}

private struct RemoteMarkdownImage: View {
    let url: URL
    let alt: String
    @State private var phase = Phase.loading
    @State private var attempt = 0
    private enum Phase { case loading, ready(CGImage), failed(String) }
    private struct Request: Hashable { let url: URL; let attempt: Int }

    var body: some View {
        Group {
            switch phase {
            case .loading: Spinner().accessibilityLabel(alt)
            case .ready(let image):
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).accessibilityLabel(alt)
            case .failed(let message):
                VStack(alignment: .leading, spacing: Spacing.item) {
                    if !alt.isEmpty { Text(alt) }
                    Text(message).font(Typography.secondary)
                    Button("重试") { attempt += 1 }.buttonStyle(PressStyle())
                }
            }
        }
        .task(id: Request(url: url, attempt: attempt)) {
            phase = .loading
            do {
                let files = try InspirationFiles()
                let asset = try await MarkdownRemoteImage.load(url, into: files)
                try Task.checkCancellation()
                phase = .ready(asset.image)
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }
}
