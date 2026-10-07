import CueStore
import Foundation

/// 资料库没能打开（迁移失败、库损坏、更新版本建的库）或读不出来：交给界面的失败结果，进程不终止（见 `UnreadableLibraryView`）。
/// `summary` 是给人看的说明；原文（`reason`）只放在折叠的详情与导出的诊断里。
struct LibraryFailure: Equatable, Sendable {
    let reason: String
    /// 库文件；位置本身解析不出来（如没有 App Group 权限）时为 nil。
    let path: String?
    /// 库文件的结构版本；读不出来为 nil。
    let version: Int?

    init(reason: String, location: LibraryLocation?) {
        self.reason = reason
        path = location?.databaseURL.path
        version = location.flatMap { CueStore.schemaVersion(of: $0.databaseURL) }
    }

    init(_ error: any Error, location: LibraryLocation?) {
        self.init(reason: (error as? any LocalizedError)?.errorDescription ?? "\(error)", location: location)
    }

    /// 库是更新版本的 CuePad 建的：这个版本打不开，更新 App 即可。
    var newerLibrary: Bool { version.map { $0 > CueStore.supportedSchemaVersion } ?? false }

    var summary: String {
        newerLibrary
            ? "这份资料库是更新版本的 CuePad 建的，请先把 CuePad 更新到最新版。你的内容没有被改动。"
            : "资料库没能打开，你的内容没有被改动。可以重试；还不行就导出诊断，发给开发者。"
    }

    /// 复制给开发者的诊断：错误原文、库文件与结构版本、App 版本。
    var diagnostics: String {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?")（\(info?["CFBundleVersion"] as? String ?? "?")）"
        return """
            CuePad 资料库诊断
            原因：\(reason)
            库文件：\(path ?? "位置解析不出来")
            库结构版本：\(version.map(String.init) ?? "读不出来")（这个版本支持 \(CueStore.supportedSchemaVersion)）
            CuePad：\(app)
            """
    }
}
