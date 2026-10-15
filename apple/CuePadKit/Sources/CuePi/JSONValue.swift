#if os(macOS)
import Foundation

/// 线上的任意 JSON（钩子输入、Claude Code stream-json 的一行、Codex app-server 的一条、settings.json 里的条目）：字段多、形状随版本变，
/// 只取用得到的几项，其余原样带着（如 `AskUserQuestion` 的 `tool_input` 作答时要整份交回）。
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else { self = .number(try c.decode(Double.self)) }
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

    /// 一段 JSON 文本；读不出为 nil。经 `JSONSerialization` 一次解完再转成枚举（Codable 逐节点试类型要抛错再接住，大行里很慢）。
    static func parse(_ data: Data) -> JSONValue? {
        (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)).map(JSONValue.init(any:))
    }

    init(any value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [Any]: self = .array(value.map(JSONValue.init(any:)))
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    private var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.any)
        case .object(let value): value.mapValues(\.any)
        }
    }

    /// 一行 JSON（不带换行）；键排序，输出稳定。
    var data: Data {
        (try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("null".utf8)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    /// 整数（JSON 里的数都读成 Double，id 与 token 数在 2^53 以内不丢精度）
    var int: Int? { number.flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements) { $1 }) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}
#endif
