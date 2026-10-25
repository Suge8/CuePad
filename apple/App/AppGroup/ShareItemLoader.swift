import CueStore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

nonisolated enum ShareError: Error, LocalizedError {
    case nothingToShare

    var errorDescription: String? { String(localized: "没有可保存的文字、网址或图片") }
}

/// 把系统分享面板给的 `NSItemProvider` 读成 `ShareContent`：图片优先，其次网址，最后文字。
/// 一个条目只取一种（网页分享常同时带网址与标题文字，标题不重复保存）。读不出的条目跳过并记一条日志。
nonisolated enum ShareItemLoader {
    private static let log = Logger(subsystem: AppIdentity.id, category: "share")

    static func load(from providers: [NSItemProvider]) async throws -> ShareContent {
        var content = ShareContent()
        var texts: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let image = await loadImage(provider) { content.images.append(image) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await loadURL(provider) { content.urls.append(url) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await loadText(provider) { texts.append(text) }
            }
        }
        content.text = texts.isEmpty ? nil : texts.joined(separator: "\n\n")
        guard !content.isEmpty else { throw ShareError.nothingToShare }
        return content
    }

    private static func loadImage(_ provider: NSItemProvider) async -> ShareContent.Image? {
        guard let data = await skippingFailure("图片", { try await loadData(provider, type: .image) }),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let fileExtension = UTType(identifier as String)?.preferredFilenameExtension
        else { return nil }
        return ShareContent.Image(data: data, fileExtension: fileExtension)
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

    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? ShareError.nothingToShare) }
            }
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
