import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 附件的键（唯一规则）：64 位小写十六进制的内容哈希（SHA-256），有扩展名时接 "." + 小写扩展名（`<hash>.pdf`）。
/// 正文里的引用、本机文件名、附件记录（`hash` + `format`）都按它；扩展名决定系统（快速查看、Agent 的读文件工具）把它认成什么。
public enum AttachmentKey {
    public static let hashLength = 64
    /// 扩展名最长几个字符：再长的不是扩展名，按没有扩展名算。
    static let formatLimit = 16

    /// 系统把 .ts、.mts 认作 MPEG-2 传输流（视频），可 Agent 与用户发来的几乎都是 TypeScript：这几个的键按文本（txt）存，
    /// 快速查看才按源代码打开。别的同名歧义系统本来就归到文本（.m、.r、.fs 都是源代码），不用改。
    static let reassigned: [String: String] = ["ts": "txt", "mts": "txt", "cts": "txt"]

    public static func make(hash: String, format: String) -> String { format.isEmpty ? hash : hash + "." + format }

    /// 文件名对应的键：扩展名取文件名的（小写、只认字母数字，`reassigned` 里的换掉），没有或不合规为空。
    public static func make(hash: String, name: String) -> String { make(hash: hash, format: format(ofName: name)) }

    /// 文件名对应的系统类型（快速查看、图标、预览的种类都按它）：按键的扩展名认，系统认错的（`reassigned`）已换掉；没有扩展名为 nil。
    public static func type(ofName name: String) -> UTType? { type(ofFormat: format(ofName: name)) }

    static func type(ofFormat format: String) -> UTType? { format.isEmpty ? nil : UTType(filenameExtension: format) }

    public static func format(ofName name: String) -> String {
        let raw = (name as NSString).pathExtension.lowercased()
        guard isFormat(Substring(raw)) else { return "" }
        return reassigned[raw] ?? raw
    }

    /// 键拆成哈希与扩展名（无扩展名为空）；不是合法的键为 nil。
    public static func parts(_ key: String) -> (hash: String, format: String)? {
        let utf8 = key.utf8
        guard utf8.count >= hashLength, utf8.prefix(hashLength).allSatisfy(isHex) else { return nil }
        let hash = String(key.prefix(hashLength)), rest = key.dropFirst(hashLength)
        if rest.isEmpty { return (hash, "") }
        guard rest.first == ".", isFormat(rest.dropFirst()) else { return nil }
        return (hash, String(rest.dropFirst()))
    }

    public static func isValid(_ key: String) -> Bool { parts(key) != nil }

    /// 这个键是不是能在正文里内联显示的图片：扩展名是图片、ImageIO 解得了（HEIC、RAW 是，PDF、SVG 不是）。
    public static func isImage(_ key: String) -> Bool {
        guard let format = parts(key)?.format, let type = type(ofFormat: format) else { return false }
        return type.conforms(to: .image) && imageTypes.contains(type.identifier)
    }

    private static let imageTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    static func isHex(_ byte: UInt8) -> Bool { (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) }

    static func isFormat(_ text: Substring) -> Bool {
        (1...formatLimit).contains(text.utf8.count) && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) }
    }
}
