import CueStore
import Foundation

extension Command {
  /// 各家 Agent 给它执行的每条 shell 命令带着当前会话的 id（Pi、Claude Code、Codex、OpenCode）。
  private static let sessionVariables = ["PI_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "OPENCODE_SESSION_ID"]

  static let show = Command(
    path: ["show"], summary: "把文件发到用户手机上的 CuePad 预览：在当前 Agent 会话的对话里出现一张卡片", arguments: "<文件>",
    options: [Opt("title", "一句标题，说明这是什么（默认用文件名）", value: "标题")],
    notes: """
      会话从 Agent 给每条命令带的环境变量认出（\(sessionVariables.joined(separator: "、"))）；不在 Agent 的命令里运行会报错，不猜是哪个会话。
      可发：\(PiPreviewKind.supportedList)；单个文件不超过 \(PiPreview.maxBytes / 1_000_000) MB。
      HTML 在手机上只读渲染、不联网，也读不到别的文件：必须是单个文件，样式与脚本写进同一个 HTML，图片用 data: 地址内联，否则会缺失
      （命令会列出页面引用了、手机上拿不到的地址 outsideReferences，改成单个文件后再发一次）。
      只发最终要给用户看的那一个文件。经 iCloud 同步，CuePad.app 需要在运行。
      \(Schema.output("Preview {id, session, title, name, kind, bytes, outsideReferences}", "kind：web、image、pdf、markdown、text"))
      """
  ) { call in
    try call.args.expect("文件")
    guard let session = sessionVariables.lazy.compactMap({ call.environment[$0] }).first(where: { !$0.isEmpty }) else {
      throw CLIError.usage("认不出是哪个 Agent 会话：环境变量 \(sessionVariables.joined(separator: "、")) 都没有设置（要在 Agent 执行的命令里运行）")
    }
    let url = URL(filePath: call.args.positionals[0], relativeTo: URL(filePath: call.directory, directoryHint: .isDirectory)).standardizedFileURL
    let added = try await call.store.addPreview(fileAt: url, title: call.args.value("title"), sessionID: session)
    let preview = added.preview
    var text = "已发到手机预览：\(preview.title)（\(preview.name)，\(preview.byteCount) 字节）\n"
    if !added.outsideReferences.isEmpty {
      text += "注意：页面引用了 \(added.outsideReferences.joined(separator: "、"))，手机上预览不联网、读不到别的文件，这些会缺失；改成单个文件后再发一次。\n"
    }
    let json: JSONObject = [
      "id": preview.id.uuidString.lowercased(), "session": session, "title": preview.title, "name": preview.name,
      "kind": preview.kind?.rawValue ?? "", "bytes": preview.byteCount, "outsideReferences": added.outsideReferences,
    ]
    return Reply(text: text, json: json)
  }
}
