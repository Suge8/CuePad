import CueStore
import Foundation
import UniformTypeIdentifiers
import os

nonisolated enum ShareError: Error, LocalizedError {
    case nothingToShare

    var errorDescription: String? { String(localized: "没有可保存的文字、网址或文件") }
}

/// 把系统分享面板给的 `NSItemProvider` 读成 `ShareContent`：文件（访达、文件 App 分享的，与图片）优先，其次网址，再次文字，
/// 别的有内容的类型也当文件收。一个条目只取一种（网页分享常同时带网址与标题文字，标题不重复保存）。读不出的条目跳过并记一条日志。
nonisolated enum ShareItemLoader {
    private static let log = Logger(subsystem: AppIdentity.id, category: "share")

    static func load(from providers: [NSItemProvider]) async throws -> ShareContent {
        var content = ShareContent()
        var texts: [String] = []
        for provider in providers {
            if let type = fileType(of: provider) {
                if let file = await skippingFailure("文件", { try await loadFile(provider, type: type) }) { content.files.append(file) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await loadURL(provider) { content.urls.append(url) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await loadText(provider) { texts.append(text) }
            } else if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) }) {
                if let file = await skippingFailure("文件", { try await loadFile(provider, type: type) }) { content.files.append(file) }
            }
        }
        content.text = texts.isEmpty ? nil : texts.joined(separator: "\n\n")
        guard !content.isEmpty else { throw ShareError.nothingToShare }
        return content
    }

    /// 当文件收的：分享的是文件（带文件网址的，取它的内容类型）或图片。
    private static func fileType(of provider: NSItemProvider) -> UTType? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { return .image }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return provider.registeredContentTypes.first { $0.conforms(to: .data) } ?? .data
    }

    /// 系统给的那份只在回调里有效：拷进扩展自己的临时目录。分享的是文件（带文件网址的）时从网址拿原文件，名字是原文件名；
    /// 别的是系统起名的临时副本，名字用分享方给的，没有就用系统的。
    private static func loadFile(_ provider: NSItemProvider, type: UTType) async throws -> ShareContent.File {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url: URL = try? await loadObject(provider), url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return ShareContent.File(url: try copy(url), name: url.lastPathComponent)
        }
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else { return continuation.resume(throwing: error ?? ShareError.nothingToShare) }
                let ext = url.pathExtension
                let name = suggested.map { ext.isEmpty || $0.lowercased().hasSuffix("." + ext.lowercased()) ? $0 : $0 + "." + ext } ?? url.lastPathComponent
                continuation.resume(with: Result { ShareContent.File(url: try copy(url), name: name) })
            }
        }
    }

    private static func copy(_ url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        guard let url: URL = await skippingFailure("网址", { try await loadObject(provider) }), !url.isFileURL else { return nil }
        return url
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        guard let text: String = await skippingFailure("文字", { try await loadObject(provider) }) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func skippingFailure<T>(_ what: String, _ load: () async throws -> T) async -> T? {
        do {
            return try await load()
        } catch {
            log.error("分享的\(what)读取失败，已跳过：\(error.localizedDescription)")
            return nil
        }
    }

    private static func loadObject<T: _ObjectiveCBridgeable & Sendable>(_ provider: NSItemProvider) async throws -> T
    where T._ObjectiveCType: NSItemProviderReading {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: T.self) { object, error in
                if let object { continuation.resume(returning: object) } else { continuation.resume(throwing: error ?? ShareError.nothingToShare) }
            }
        }
    }
}
