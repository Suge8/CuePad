import CueStore
import Foundation

extension CueTools {
  /// 灵感属于项目里的卡片；Cue 的长期记忆由 memory 管理。保存成功才回执，失败沿工具的错误通道返回。
  static var ideaDefinition: [String: Any] {
    [
      "name": "idea",
      "description": """
        记一条灵感到项目里。idea{text,project?}，没有 action。text 是他要保存的内容，保留原意与细节；project 写项目名或 id 前缀，不给进默认项目。保存的是用户能在项目里看到的灵感，不建任务、不开工，也不写你的长期记忆。工具成功才告诉他已保存；失败说明原因，不改存记忆冒充成功。
        """,
      "inputSchema": schema(["text": string, "project": string], required: ["text"]),
      "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
    ]
  }

  func idea(_ args: Args) async throws -> Result {
    let text = try args.required("text")
    let project = try await args.string("project").asyncMap(references.project)
    let projectID = project?.id ?? Project.defaultID
    let projectName = try await store.project(projectID)?.name ?? ""
    let card = try await store.createCard(in: projectID, body: text)
    return .ok("已保存灵感（\(card.id.shortID)），在项目「\(projectName)」里。")
  }
}
