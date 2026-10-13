#if os(macOS)
import Foundation

/// 按原文改一份 JSON 文本：只在要加、要删的地方动字节，别处（键序、缩进、空白、转义写法）一个字节都不变。
/// 用户的 settings.json 是手写或别的程序写的，整份重新序列化会改掉它的样子；CuePad 加进去的再删掉后要与原文逐字节一致。
struct ClaudeJSONText {
    private(set) var bytes: [UInt8]

    init(_ data: Data) { bytes = Array(data) }

    var data: Data { Data(bytes) }

    struct Malformed: Error {}

    /// 一个值在原文里的位置 `[start, end)`；对象的成员带键，数组的元素键为 nil。
    struct Node {
        var start: Int
        var end: Int
        var kind: Kind
        enum Kind { case object, array, scalar }
        var items: [(key: String?, start: Int, value: Node)] = []

        func member(_ key: String) -> (index: Int, value: Node)? {
            items.firstIndex { $0.key == key }.map { ($0, items[$0].value) }
        }
    }

    func root() throws -> Node {
        var parser = Parser(bytes: bytes)
        parser.skipSpace()
        let node = try parser.value()
        parser.skipSpace()
        guard parser.position == bytes.count else { throw Malformed() }
        return node
    }

    /// 这个值的原文。
    func text(of node: Node) -> Data { Data(bytes[node.start..<node.end]) }

    /// 原文里除了空白就是一个空对象。
    var isEmptyObject: Bool {
        guard let node = try? root(), node.kind == .object else { return false }
        return node.items.isEmpty
    }

    /// 删掉容器 `container` 里第 `index` 项：是最后一项时连同它前面的逗号与空白一起删（正好是 `append` 加进去的那段），
    /// 否则连同它后面到下一项之前的部分删；只剩它一项时容器里清空。
    mutating func remove(_ index: Int, in container: Node) {
        let items = container.items
        let range: Range<Int>
        if items.count == 1 {
            range = (container.start + 1)..<(container.end - 1)
        } else if index == items.count - 1 {
            range = items[index - 1].value.end..<items[index].value.end
        } else {
            range = items[index].start..<items[index + 1].start
        }
        bytes.removeSubrange(range)
    }

    /// 在容器末尾加一项（对象的成员写成 `"键": 值`）。`render` 按给定的缩进写出值，写多行时续行用它。
    mutating func append(key: String?, in container: Node, render: (_ indent: String, _ unit: String) -> String) {
        let unit = indentUnit
        let base = indentation(at: container.start)
        let inner = base + unit
        let item = (key.map { Self.quoted($0) + ": " } ?? "") + render(inner, unit)
        if let last = container.items.last {
            bytes.insert(contentsOf: Array(",\n\(inner)\(item)".utf8), at: last.value.end)
        } else {
            bytes.replaceSubrange((container.start + 1)..<(container.end - 1), with: Array("\n\(inner)\(item)\n\(base)".utf8))
        }
    }

    static func quoted(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(string)) ?? Data(), as: UTF8.self)
    }

    /// 文件用的缩进单位：顶层对象第一项那一行的缩进；看不出来时两个空格。
    private var indentUnit: String {
        guard let root = try? root(), let first = root.items.first else { return "  " }
        let indent = indentation(at: first.start)
        return indent.isEmpty ? "  " : indent
    }

    /// `offset` 所在那一行开头的空白。
    private func indentation(at offset: Int) -> String {
        var start = offset
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < offset, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        mutating func skipSpace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }

        mutating func value() throws -> Node {
            guard position < bytes.count else { throw Malformed() }
            let start = position
            switch bytes[position] {
            case UInt8(ascii: "{"):
                position += 1
                var items: [(key: String?, start: Int, value: Node)] = []
                skipSpace()
                if peek(UInt8(ascii: "}")) { position += 1; return Node(start: start, end: position, kind: .object) }
                while true {
                    skipSpace()
                    let keyStart = position
                    let key = try string()
                    skipSpace()
                    try expect(UInt8(ascii: ":"))
                    skipSpace()
                    items.append((key: key, start: keyStart, value: try value()))
                    skipSpace()
                    if peek(UInt8(ascii: ",")) { position += 1; continue }
                    try expect(UInt8(ascii: "}"))
                    return Node(start: start, end: position, kind: .object, items: items)
                }
            case UInt8(ascii: "["):
                position += 1
                var items: [(key: String?, start: Int, value: Node)] = []
                skipSpace()
                if peek(UInt8(ascii: "]")) { position += 1; return Node(start: start, end: position, kind: .array) }
                while true {
                    skipSpace()
                    let itemStart = position
                    items.append((key: nil, start: itemStart, value: try value()))
                    skipSpace()
                    if peek(UInt8(ascii: ",")) { position += 1; continue }
                    try expect(UInt8(ascii: "]"))
                    return Node(start: start, end: position, kind: .array, items: items)
                }
            case UInt8(ascii: "\""):
                _ = try string()
            default:
                while position < bytes.count, !",]} \t\r\n".utf8.contains(bytes[position]) { position += 1 }
                guard position > start else { throw Malformed() }
                guard (try? JSONDecoder().decode(ClaudeJSON.self, from: Data(bytes[start..<position]))) != nil else { throw Malformed() }
            }
            return Node(start: start, end: position, kind: .scalar)
        }

        private func peek(_ byte: UInt8) -> Bool { position < bytes.count && bytes[position] == byte }

        private mutating func expect(_ byte: UInt8) throws {
            guard peek(byte) else { throw Malformed() }
            position += 1
        }

        private mutating func string() throws -> String {
            let start = position
            try expect(UInt8(ascii: "\""))
            while position < bytes.count, bytes[position] != UInt8(ascii: "\"") {
                position += bytes[position] == UInt8(ascii: "\\") ? 2 : 1
            }
            try expect(UInt8(ascii: "\""))
            guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) else { throw Malformed() }
            return value
        }
    }
}
#endif
