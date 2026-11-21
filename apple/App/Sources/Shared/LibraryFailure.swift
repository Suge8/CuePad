import CueStore
import Foundation

struct LibraryFailure: Equatable, Sendable {
    let reason: String
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
