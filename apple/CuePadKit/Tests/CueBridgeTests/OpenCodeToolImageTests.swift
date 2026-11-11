#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import ImageIO
import Testing
@testable import CueBridge

/// `Fixtures/opencode/imageToolResult.json` 是服务 `/api/session/<id>/message` 原样返回的那一页；OpenCode 自己把图转成 2000×1000 的 jpeg 放进 `state.content`。
struct OpenCodeToolImageTests {
    @Test func aToolResultImageIsShrunkAndTheSameImageReadTwiceIsStoredOnce() throws {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/opencode/imageToolResult.json")
        let page = try JSONDecoder().decode(OpenCodePage<OpenCodeMessage>.self, from: Data(contentsOf: fixture))
        let files = try Fixture().store.files
        var checkpoint = HistoryCheckpoint()
        var transcript = History.Transcript(fallbackID: "s", files: files)
        for (seq, message) in page.data.enumerated() { try OpenCodeHistory.ingest(message, seq: Int64(seq), &checkpoint, &transcript) }

        let answer = try #require(transcript.messages.last)
        let keys = try #require(answer.tools).images
        #expect(keys.count == 1)
        let stored = try #require(files.fileURL(for: keys[0]))
        let properties = try #require(CGImageSourceCreateWithURL(stored as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        #expect((properties[kCGImagePropertyPixelWidth] as? Int) == ToolImage.maxPixels)
    }
}
#endif
