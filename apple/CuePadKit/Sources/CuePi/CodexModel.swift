#if os(macOS)
import CueStore
import CueText
import Foundation

/// `model/list` 里的一个模型：强度是 Codex 的 `ReasoningEffort`（`none` 即关闭；`ultra` 等 CuePad 没有的档丢掉）；
/// fast 只取 `serviceTiers` 里的 `priority`。
struct CodexModel {
    let id: String
    let name: String
    let efforts: [PiThinkingLevel]
    /// 能看图（`inputModalities` 里有 image）
    let seesImages: Bool
    let supportsFast: Bool
    /// 用户没配模型时 Codex 用的那个
    let isDefault: Bool

    /// 模型的提供方写成 Codex 自己（`AgentKind.modelProvider`），不用线程上的 `modelProvider`（openai 等）：Codex 的模型 id 在它自己的命名空间里。
    static let provider = AgentKind.codex.modelProvider!

    var option: PiModelOption {
        PiModelOption(key: PiModelKey(provider: Self.provider, id: id), name: name, thinkingLevels: efforts, acceptsImages: seesImages, supportsFast: supportsFast)
    }

    static func thinking(_ effort: String) -> Open<PiThinkingLevel> { Open(rawValue: effort == "none" ? "off" : effort) }
    static func effort(_ level: PiThinkingLevel) -> String { level == .off ? "none" : level.rawValue }

    /// 失败的一轮（`turn/completed` 的 `status` 为 failed）的原因：`turn.error` 的说明，带上补充细节。
    static func failure(of turn: JSONValue?) -> String {
        let message = [turn?["error"]?["message"]?.string, turn?["error"]?["additionalDetails"]?.string].compactMap { $0 }.filter { !$0.isEmpty }
        return message.isEmpty ? String(localized: "Codex 这一轮失败了") : message.joined(separator: "\n")
    }

    /// `hidden`：连隐藏的模型也要（大脑可能配的就是它）。
    @MainActor static func list(_ rpc: CodexRPC, hidden: Bool = false) async throws -> [CodexModel] {
        let listed = try await rpc.call("model/list", hidden ? ["includeHidden": true, "limit": 500] : [:])
        return (listed["data"]?.array ?? []).compactMap { entry in
            guard hidden || entry["hidden"]?.bool != true, let id = entry["id"]?.string else { return nil }
            let efforts = (entry["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string }
            // 没写 inputModalities 的按协议缺省（文字与图片）
            let seesImages = entry["inputModalities"]?.array.map { $0.contains("image") } ?? true
            return CodexModel(
                id: id, name: entry["displayName"]?.string ?? id, efforts: efforts.compactMap { thinking($0).known }, seesImages: seesImages,
                supportsFast: entry["serviceTiers"]?.array?.contains { $0["id"]?.string == "priority" } == true,
                isDefault: entry["isDefault"]?.bool == true)
        }
    }
}
#endif
