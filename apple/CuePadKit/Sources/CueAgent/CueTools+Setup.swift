import CueStore
import Foundation

extension CueTools {
  /// setup 的说明与参数：Cue 读自己与这台 Mac（大脑、Agent 与模型、额度、技能与规则、项目、健康），改自己的大脑设置与项目。
  static var setupDefinition: [String: Any] {
    [
      "name": "setup",
      "description": "TODO",
      "inputSchema": schema(["action": ["type": "string", "enum": ["look"]]], required: ["action"]),
      "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
    ]
  }

  func setup(_ args: Args) async throws -> Result {
    throw Failure("setup 还没实现")
  }
}
