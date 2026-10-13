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

    /// 删掉容器 `container` 里第 `index` 项，正好删掉 `append` 加它时加进去的字节：是最后一项时连同它前面的逗号与空白，
    /// 只剩它一项时只删它自己（容器里原有的空白不动），否则连同它后面到下一项之前的部分。
    mutating func remove(_ index: Int, in container: Node) {
        let items = container.items
        let range: Range<Int>
        if items.count == 1 {
            range = items[index].start..<items[index].value.end
        } else if index == items.count - 1 {
            range = items[index - 1].value.end..<items[index].value.end
        } else {
            range = items[index].start..<items[index + 1].start
        }
        bytes.removeSubrange(range)
    }

    /// 在容器末尾加一项（对象的成员写成 `"键": 值`）。非空容器在最后一项后面接 `,\n<缩进>`；空容器紧贴着左括号放进去，
    /// 原有的空白一个字节不动——删掉它（`remove`）就回到原样。
    mutating func append(key: String?, in container: Node, render: (_ indent: String, _ unit: String) -> String) {
        let item = itemText(key: key, in: container, render: render)
        if let last = container.items.last {
            bytes.insert(contentsOf: Array(",\n\(context(of: container).inner)\(item)".utf8), at: last.value.end)
        } else {
            bytes.insert(contentsOf: Array(item.utf8), at: container.start + 1)
        }
    }

    /// `append` 会在这个容器里写出的那一项（从键到值的末尾）。
    func itemText(key: String?, in container: Node, render: (_ indent: String, _ unit: String) -> String) -> String {
        let context = context(of: container)
        return (key.map { Self.quoted($0) + ": " } ?? "") + render(context.inner, context.unit)
    }

    /// 容器里第 `index` 项的原文（从键到值的末尾）。
    func itemText(_ index: Int, in container: Node) -> String {
        String(decoding: bytes[container.items[index].start..<container.items[index].value.end], as: UTF8.self)
    }

    /// 容器里的项所用的缩进：容器所在那一行的缩进再加一级。
    private func context(of container: Node) -> (inner: String, unit: String) {
        let unit = indentUnit
        return (indentation(at: container.start) + unit, unit)
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
