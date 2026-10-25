#if os(macOS)
import Foundation

/// JSON 原文里每个值的位置（字节区间），用来就地插入、删除而不重写整份文件。
struct JSONSourceTree {
    let text: Data
    let root: Node

    struct Node {
        var range: Range<Int>
        /// 对象的成员（键与键的起点）；不是对象为 nil
        var memberList: [(key: String, keyStart: Int, value: Node)]?
        var elements: [Node]?

        var members: [(key: String, keyStart: Int, value: Node)] { memberList ?? [] }

        func member(_ key: String) -> Node? { memberList?.last { $0.key == key }?.value }

        /// 删一个元素：有前一个就连同它之后的逗号一起删到这个元素末尾（插入的逆操作），否则删到下一个元素开头。
        func removing(element index: Int, in text: Data) -> Data {
            let items = elements ?? []
            let range = index > 0 ? items[index - 1].range.upperBound..<items[index].range.upperBound
                : items.count > 1 ? items[index].range.lowerBound..<items[index + 1].range.lowerBound
                : items[index].range
            return Self.removing(range, from: text)
        }

        func removing(member key: String, in text: Data) -> Data {
            let items = members
            guard let index = items.lastIndex(where: { $0.key == key }) else { return text }
            let range = index > 0 ? items[index - 1].value.range.upperBound..<items[index].value.range.upperBound
                : items.count > 1 ? items[index].keyStart..<items[index + 1].keyStart
                : items[index].keyStart..<items[index].value.range.upperBound
            return Self.removing(range, from: text)
        }

        /// 在最后一个元素之后插（`,<元素>`），空数组插在 `[` 之后。
        func insertion(element: String) -> (at: Int, text: String) {
            guard let last = elements?.last else { return (range.lowerBound + 1, element) }
            return (last.range.upperBound, "," + element)
        }

        func insertion(member: String) -> (at: Int, text: String) {
            guard let last = memberList?.last else { return (range.lowerBound + 1, member) }
            return (last.value.range.upperBound, "," + member)
        }

        func inserting(member: String, in text: Data) -> Data {
            let edit = insertion(member: member)
            var result = text
            result.insert(contentsOf: Data(edit.text.utf8), at: result.startIndex + edit.at)
            return result
        }

        private static func removing(_ range: Range<Int>, from text: Data) -> Data {
            var result = text
            result.removeSubrange((result.startIndex + range.lowerBound)..<(result.startIndex + range.upperBound))
            return result
        }
    }

    struct Malformed: Error {}

    init(_ text: Data) throws {
        self.text = text
        var scanner = Scanner(bytes: [UInt8](text))
        scanner.skipSpace()
        root = try scanner.value()
        guard root.memberList != nil else { throw Malformed() }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> Node {
            guard index < bytes.count else { throw Malformed() }
            let start = index
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [(String, Int, Node)] = []
                skipSpace()
                if peek(UInt8(ascii: "}")) { index += 1; return Node(range: start..<index, memberList: []) }
                while true {
                    skipSpace()
                    let keyStart = index
                    try string()
                    guard let key = (try? JSONSerialization.jsonObject(with: Data(bytes[keyStart..<index]), options: .fragmentsAllowed)) as? String
                    else { throw Malformed() }
                    skipSpace()
                    try expect(UInt8(ascii: ":"))
                    skipSpace()
                    members.append((key, keyStart, try value()))
                    skipSpace()
                    if peek(UInt8(ascii: ",")) { index += 1; continue }
                    try expect(UInt8(ascii: "}"))
                    return Node(range: start..<index, memberList: members.map { (key: $0.0, keyStart: $0.1, value: $0.2) })
                }
            case UInt8(ascii: "["):
                index += 1
                var elements: [Node] = []
                skipSpace()
                if peek(UInt8(ascii: "]")) { index += 1; return Node(range: start..<index, elements: []) }
                while true {
                    skipSpace()
                    elements.append(try value())
                    skipSpace()
                    if peek(UInt8(ascii: ",")) { index += 1; continue }
                    try expect(UInt8(ascii: "]"))
                    return Node(range: start..<index, elements: elements)
                }
            case UInt8(ascii: "\""):
                try string()
            default:
                while index < bytes.count, !",]} \t\r\n".utf8.contains(bytes[index]) { index += 1 }
                guard index > start else { throw Malformed() }
            }
            return Node(range: start..<index)
        }

        private func peek(_ byte: UInt8) -> Bool { index < bytes.count && bytes[index] == byte }

        private mutating func expect(_ byte: UInt8) throws {
            guard peek(byte) else { throw Malformed() }
            index += 1
        }

        private mutating func string() throws {
            try expect(UInt8(ascii: "\""))
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""): index += 1; return
                default: index += 1
                }
            }
            throw Malformed()
        }
    }
}
#endif
