#if os(macOS)
import Foundation

enum LibraryFileReading {
    static func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) || RelativeLink.isLink(file) }

    static func read(_ file: URL) -> String? { (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) } }

    static func content(_ file: URL) -> String? {
        read(file).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    static func modified(_ file: URL) -> Date? {
        ((try? FileManager.default.attributesOfItem(atPath: file.realPath.path))?[.modificationDate] as? Date)
            .map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
    }
}
#endif
