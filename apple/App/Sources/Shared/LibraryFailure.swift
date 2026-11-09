import CueStore
import Foundation

/// 交给界面的失败结果，进程不终止。`summary` 是给人看的说明；原文（`reason`）只放在折叠的详情与导出的诊断里。
struct LibraryFailure: Equatable, Sendable {
    let reason: String
    /// 库文件；位置本身解析不出来（如没有 App Group 权限）时为 nil。
    let path: String?
    let version: Int?

    init(reason: String, location: LibraryLocation?) {
        self.reason = reason
        path = location?.databaseURL.path
        version = location.flatMap { CueStore.schemaVersion(of: $0.databaseURL) }
    }

    init(_ error: any Error, location: LibraryLocation?) {
        self.init(reason: (error as? any LocalizedError)?.errorDescription ?? "\(error)", location: location)
    }

    var newerLibrary: Bool { version.map { $0 > CueStore.supportedSchemaVersions.upperBound } ?? false }

    /// 版本 0 是空库，照常新建。
    var olderLibrary: Bool { version.map { $0 > 0 && $0 < CueStore.supportedSchemaVersions.lowerBound } ?? false }

    var summary: String {
        if newerLibrary { return String(localized: "这份资料库是更新版本的 CuePad 建的，请先把 CuePad 更新到最新版。你的内容没有被改动。") }
        if olderLibrary { return String(localized: "这份资料库是更早版本的 CuePad 建的，这个版本不再升级它。你的内容没有被改动，请导出诊断，发给开发者。") }
        return String(localized: "资料库没能打开，你的内容没有被改动。")
    }

    var diagnostics: String {
        """
            CuePad 资料库诊断
            原因：\(reason)
            库文件：\(path ?? "位置解析不出来")
            库结构版本：\(version.map(String.init) ?? "读不出来")（这个版本支持 \(CueStore.supportedSchemaVersions.lowerBound)–\(CueStore.supportedSchemaVersions.upperBound)）
            CuePad：\(AppServices.version)
            """
    }
}
