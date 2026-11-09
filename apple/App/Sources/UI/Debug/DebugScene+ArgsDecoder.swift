#if DEBUG
import Foundation

/// 参数组：键 = `-CuePad` + `prefix` + 字段名。
nonisolated protocol DebugArgGroup: Decodable {
    static var prefix: String { get }
}

extension DebugArgs {
    /// 本次启动的参数。只认参数域，不读已存的偏好（`UserDefaults.standard` 是真实的偏好域）。
    nonisolated static let launch: DebugArgs = {
        let domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var values: [String: String] = [:]
        for (key, value) in domain where key.lowercased().hasPrefix("cuepad") { values[String(key.lowercased().dropFirst(6))] = "\(value)" }
        do { return try DebugArgs(from: ArgDecoder(values: values, prefix: "")) } catch { fatalError("启动参数解不出来：\(error)") }
    }()

    /// 同 `NSString.boolValue`（`UserDefaults.bool` 的规则）：YES、true、1 为真。
    nonisolated static func isOn(_ text: String) -> Bool { (text as NSString).boolValue }
}

/// 把参数域里的字符串按字段类型解成 Decodable：没给的 Bool 是 false、数是 0（同 `UserDefaults.bool(forKey:)`、`double(forKey:)`），可选是 nil。
private nonisolated struct ArgDecoder: Decoder {
    let values: [String: String]
    let prefix: String
    var codingPath: [CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(Keys<Key>(values: values, prefix: prefix))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer { throw DecodingError.typeMismatch(Self.self, .init(codingPath: [], debugDescription: "启动参数没有数组")) }
    func singleValueContainer() throws -> SingleValueDecodingContainer { throw DecodingError.typeMismatch(Self.self, .init(codingPath: [], debugDescription: "启动参数没有裸值")) }

    struct Keys<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let values: [String: String]
        let prefix: String
        var codingPath: [CodingKey] { [] }
        var allKeys: [Key] { [] }

        private func text(_ key: Key) -> String? { values[(prefix + key.stringValue).lowercased()] }
        func contains(_ key: Key) -> Bool { text(key) != nil }
        func decodeNil(forKey key: Key) -> Bool { text(key) == nil }
        func decode(_ type: Bool.Type, forKey key: Key) -> Bool { text(key).map(DebugArgs.isOn) ?? false }
        func decode(_ type: Int.Type, forKey key: Key) -> Int { text(key).map { ($0 as NSString).integerValue } ?? 0 }
        func decode(_ type: Double.Type, forKey key: Key) -> Double { text(key).map { ($0 as NSString).doubleValue } ?? 0 }
        func decode(_ type: String.Type, forKey key: Key) throws -> String {
            guard let text = text(key) else { throw DecodingError.keyNotFound(key, .init(codingPath: [], debugDescription: "没给")) }
            return text
        }
        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            guard let group = type as? any DebugArgGroup.Type else { throw DecodingError.typeMismatch(type, .init(codingPath: [], debugDescription: "只支持 Bool、数、字符串与参数组")) }
            return try group.init(from: ArgDecoder(values: values, prefix: group.prefix)) as! T
        }

        func decode(_ type: Float.Type, forKey key: Key) throws -> Float { fatalError("不用") }
        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { fatalError("不用") }
        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { fatalError("不用") }
        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { fatalError("不用") }
        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { fatalError("不用") }
        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { fatalError("不用") }
        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { fatalError("不用") }
        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { fatalError("不用") }
        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { fatalError("不用") }
        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { fatalError("不用") }
        func nestedContainer<N: CodingKey>(keyedBy type: N.Type, forKey key: Key) throws -> KeyedDecodingContainer<N> { fatalError("不用") }
        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { fatalError("不用") }
        func superDecoder() throws -> Decoder { fatalError("不用") }
        func superDecoder(forKey key: Key) throws -> Decoder { fatalError("不用") }
    }
}
#endif
