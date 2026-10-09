#if os(macOS)
import CuePi
import Foundation

/// Agent 发到手机上看的文件（Pi 里的 `cuepad_show` 工具经桥转来）：存成这个会话的预览，同步给手机。
extension AppServices {
    func showPreview(_ request: PiShowRequest, from session: CuePi.PiSession) async throws -> PiShowReply {
        let added = try await store.addPreview(fileAt: URL(filePath: request.path), title: request.title, sessionID: session.sessionID)
        return PiShowReply(preview: added.preview.id.uuidString.lowercased(), note: Self.outsideNote(added.outsideReferences))
    }

    /// 页面引用了手机上拿不到的外部资源时，告诉 Agent 缺了什么、怎么改。
    private static func outsideNote(_ references: [String]) -> String? {
        guard !references.isEmpty else { return nil }
        return "页面引用了 \(references.joined(separator: "、"))，手机上预览不联网、读不到别的文件，这些会缺失。把样式与脚本写进同一个 HTML、图片用 data: 地址内联后，再发一次。"
    }
}
#endif
