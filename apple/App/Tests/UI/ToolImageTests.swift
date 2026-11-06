#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import Foundation
import ImageIO
import Testing
@testable import CuePad

/// 工具结果里的图（Agent 截的屏、读进来的图）：Mac 读会话时缩小存进附件、记在那一步上，会话页那一轮的经过下面是它的缩略图（`RoundProcess` 读
/// `Tools.images`），点开在全屏页里看、几张左右翻。大的缩到长边 1600，小的原样；同一张反复读只存一份。
@MainActor
struct ToolImageTests {
    @Test func 工具结果带图的一轮_经过下有缩略图_点开全屏_同一张只存一份() async throws {
        let app = TestApp()
        defer { app.services.cancelBackgroundWork() }
        let store = app.services.store, files = store.files
        let file = app.directory.appending(path: "shots.jsonl"), log = SessionFile(url: file, sessionID: "s", cwd: app.directory.path)
        try log.reset()
        let shot = pngData(width: 3200, height: 2000, shade: 0.3), icon = pngData(width: 40, height: 40, shade: 0.6)
        try log.user("截个图看看")
        try log.tool("read", id: "c1", arguments: ["path": "shot.png"], images: [shot])
        try log.tool("read", id: "c2", arguments: ["path": "icon.png"], images: [icon])
        try log.tool("read", id: "c3", arguments: ["path": "shot.png"], images: [shot])
        try log.reply("截好了")
        let update = try PiHistory.index(file: file, agent: .pi, from: nil, files: files)
        await app.services.consumePiHistory(AsyncStream { $0.yield(.updated(update)); $0.finish() }, agent: .pi)

        let round = try #require(try await store.piMessages(of: "s").last { $0.role == .known(.pi) })
        let images = try #require(round.tools?.images)
        #expect(images.count == 2)
        let shrunk = try #require(files.fileURL(for: images[0]))
        let size = try #require(CGImageSourceCreateWithURL(shrunk as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any])
        #expect(size[kCGImagePropertyPixelWidth] as? Int == 1600 && size[kCGImagePropertyPixelHeight] as? Int == 1000)
        #expect(try Data(contentsOf: #require(files.fileURL(for: images[1]))) == icon)
        for key in images { #expect(try await store.hasAttachment(key)) }

        let workspace = Workspace(services: app.services)
        let all = images.map { DraftFile(key: $0, name: "") }
        workspace.openAttachment(all[1], among: all, group: "chat-" + images.joined(separator: ","), with: nil)
        #expect(workspace.preview?.preview.key == images[1] && workspace.preview?.batch.map(\.key) == images)
    }
}
#endif
