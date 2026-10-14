#if os(macOS)
import Foundation

/// Claude Code 线上的任意 JSON（钩子输入、stream-json 的一行、settings.json 里的条目）：字段多、形状随版本变，只取用得到的几项，
/// 其余原样带着（如 `AskUserQuestion` 的 `tool_input` 作答时要整份交回）。
enum ClaudeJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ClaudeJSON])
    case object([String: ClaudeJSON])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([ClaudeJSON].self) { self = .array(value) }
        else { self = .object(try c.decode([String: ClaudeJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    static func parse(_ data: Data) -> ClaudeJSON? { try? JSONDecoder().decode(ClaudeJSON.self, from: data) }

    /// 一行 JSON（不带换行）；键排序，输出稳定。
    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    subscript(key: String) -> ClaudeJSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var array: [ClaudeJSON]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: ClaudeJSON]? { if case .object(let value) = self { value } else { nil } }
}

extension ClaudeJSON: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(dictionaryLiteral elements: (String, ClaudeJSON)...) { self = .object(Dictionary(elements) { $1 }) }
    init(arrayLiteral elements: ClaudeJSON...) { self = .array(elements) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}
#endif
