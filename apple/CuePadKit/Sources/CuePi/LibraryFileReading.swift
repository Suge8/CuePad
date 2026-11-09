#if os(macOS)
import Foundation

/// 扫描与编辑共用文件读法，保证展示正文与写前比较的基准相同；技能的空文本由调用方保留。
enum LibraryFileReading {
    static func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) || RelativeLink.isLink(file) }

    static func read(_ file: URL) -> String? { (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) } }

    /// 一份规则的正文：空的（0 字节、只有空白）等同没有——不算哪家写了一份、不进合并，项目里写"还没有"。
    static func content(_ file: URL) -> String? {
        read(file).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// 取整到秒：快照按 1970 起的秒存（`StoredJSON`），带小数的时刻存回来差最后一位，每次重读都当成变了、重写重传。
    static func modified(_ file: URL) -> Date? {
        ((try? FileManager.default.attributesOfItem(atPath: file.realPath.path))?[.modificationDate] as? Date)
            .map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
    }
}
#endif
