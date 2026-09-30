#if os(iOS)
import CueStore
import Foundation
import Testing
import UIKit
@testable import CuePad

@MainActor
struct IOSTests {
    @Test func 真实位置在App_Group共享容器里_偏好用该组的套件() throws {
        let container = try #require(AppGroup.containerURL, "模拟器里应能取到 App Group 容器（权限没有生效？）")

        let location = try LibraryLocation.resolve(environment: [:])

        #expect(location.directory.path.hasPrefix(container.path))
        #expect(location.preferencesSuite == AppGroup.identifier)
        #expect(location.electronDatabase == nil)
    }

    @Test func 没有App_Group权限时明确报错() {
        #expect(throws: LibraryLocationError.self) {
            try LibraryLocation.resolve(environment: [:], appGroupContainer: nil)
        }
    }

    @Test func iOS上发送只有剪贴板_文字与图片按顺序各成一个条目() async throws {
        let app = TestApp()
        let png = pngData()
        let hash = try app.services.images.store(png)

        try await app.services.send("前\n![](cuepad://img/\(hash))\n后", to: .clipboard)

        let items = app.pasteboard.items
        #expect(items.count == 3)
        #expect(items[0]["public.utf8-plain-text"] as? String == "前\n")
        // 系统可能重新编码图片：只确认第二项是这张 4×4 的 PNG
        let image = try #require(app.pasteboard.data(forPasteboardType: "public.png", inItemSet: IndexSet(integer: 1))?.first ?? nil)
        #expect(UIImage(data: image)?.size == CGSize(width: 4, height: 4))
        #expect(items[2]["public.utf8-plain-text"] as? String == "\n后")
        let record = try #require(try await app.services.store.sendRecords().first)
        #expect(record.targetKind == .clipboard)
    }
}
#endif
