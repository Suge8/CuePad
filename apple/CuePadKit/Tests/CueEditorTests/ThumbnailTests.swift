import CueEditor
import Foundation
import Testing

/// 缩略图（编辑器与卡片墙共用）：按最长边降采样，不放大。
@Suite struct ThumbnailTests {
    @Test func boundedByMaxPixelAndNeverUpscaled() throws {
        let store = DirectoryImageStore()
        let url = try #require(store.fileURL(for: try store.store(makePNG(width: 400, height: 200))))

        let small = try #require(Thumbnails.image(at: url, maxPixel: 100))
        #expect(small.width == 100 && small.height == 50)
        let unchanged = try #require(Thumbnails.image(at: url, maxPixel: 1000))
        #expect(unchanged.width == 400 && unchanged.height == 200)
    }
}
