import CueStore
import Foundation

extension Command {
  private static let sessionVariables = [AgentKind.watchedSessionVariable] + AgentKind.allCases.map(\.sessionVariable)

  static let show = Command(
    path: ["show"], summary: "把文件发到用户手机上的 CuePad：当前 Agent 会话的对话里出现一张卡片", arguments: "<文件…> --title <标题>…",
    options: [Opt("title", "按文件的先后每个一句，\(PiPreview.titleRule)", value: "标题")],
    notes: """
      会话取 Agent 给每条命令带的环境变量里第一个有值的：\(sessionVariables.joined(separator: "、"))。\(AgentKind.watchedSessionVariable) 是 CuePad 的 Pi 扩展给的、用户在看的会话，子代理发的也落在它的对话里。都没有就报错，不猜。
      一次给几个文件是同一张卡，点开后左右切换；用户看到的是标题，不是文件名。
      可发：\(PiPreviewKind.supportedList)；单个不超过 \(PiPreview.maxBytes / 1_000_000) MB。Markdown 排成文稿，diff、patch 是增删对照。
      网页只读、不联网、读不到别的文件；outsideReferences 是页面引用了、手机上因此缺失的地址。经 iCloud 同步，CuePad.app 需要在运行。
      \(Schema.output("[Preview {id, session, title, name, kind, bytes, outsideReferences}]", "kind：\(PiPreviewKind.allCases.map(\.rawValue).joined(separator: "、"))"))
      """
  ) { call in
    let paths = call.args.positionals
    guard !paths.isEmpty else { throw CLIError.usage("需要至少一个 <文件>") }
    guard let session = sessionVariables.lazy.compactMap({ call.environment[$0] }).first(where: { !$0.isEmpty }) else {
      throw CLIError.invalid("不在 Agent 会话里：\(sessionVariables.joined(separator: "、")) 都没有值。show 只能在 Agent 执行的命令里运行，卡片发到那个会话的对话里")
    }
    let titles = call.args.all("title")
    guard titles.count == paths.count else {
      throw CLIError.usage("\(paths.count) 个文件要 \(paths.count) 个 --title（给了 \(titles.count) 个），按文件的先后每个一句，\(PiPreview.titleRule)")
    }
    let directory = URL(filePath: call.directory, directoryHint: .isDirectory)
    let urls = paths.map { URL(filePath: $0, relativeTo: directory).standardizedFileURL }
    let added = try await call.store.addPreviews(Array(zip(urls, titles)).map { (url: $0, title: $1) }, sessionID: session)
    var text = "已发到手机：" + added.map { "「\($0.preview.title)」\($0.preview.name)（\($0.preview.byteCount) 字节）" }.joined(separator: "、") + "\n"
    for item in added where !item.outsideReferences.isEmpty {
      text += "注意：\(item.preview.name) 引用的 \(item.outsideReferences.joined(separator: "、")) 在手机上拿不到（只读这一个文件、不联网）；写进同一个文件后再发一次。\n"
    }
    let json: [JSONObject] = added.map { item in
      let preview = item.preview
      return [
        "id": preview.id.uuidString.lowercased(), "session": session, "title": preview.title, "name": preview.name,
        "kind": preview.kind?.rawValue ?? "", "bytes": preview.byteCount, "outsideReferences": item.outsideReferences,
      ]
    }
    return Reply(text: text, json: json)
  }
}
