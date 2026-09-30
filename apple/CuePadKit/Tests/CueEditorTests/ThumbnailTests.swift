import CueEditor
import Foundation
import Testing

/// 缩略图（编辑器与卡片墙共用）：按最长边降采样、不放大，解码结果按尺寸缓存。
@Suite struct ThumbnailTests {
    @Test func boundedByMaxPixelNeverUpscaledAndCachedPerSize() throws {
        let store = DirectoryImageStore()
        let url = try #require(store.fileURL(for: try store.store(makePNG(width: 400, height: 200))))

        let small = try #require(Thumbnails.image(at: url, maxPixel: 100))
        #expect(small.width == 100 && small.height == 50)
        let unchanged = try #require(Thumbnails.image(at: url, maxPixel: 1000))
        #expect(unchanged.width == 400 && unchanged.height == 200)

        #expect(Thumbnails.cached(at: url, maxPixel: 100) === small)
        #expect(Thumbnails.cached(at: url, maxPixel: 50) == nil)
    }

    @Test func nonImageFileHasNoThumbnail() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "not-image-\(UUID().uuidString)")
        try Data("text".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Thumbnails.image(at: url, maxPixel: 100) == nil)
    }
}
