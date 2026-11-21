import CueStore
import Foundation

private struct PreviewOutput {
  let id: String
  let session: String
  let title: String
  let name: String
  let kind: String
  let bytes: Int
  let outsideReferences: [String]
  static let fields = OutputFields<PreviewOutput>(fields: [
    ("id", { $0.id }), ("session", { $0.session }), ("title", { $0.title }), ("name", { $0.name }),
    ("kind", { $0.kind }), ("bytes", { $0.bytes }), ("outsideReferences", { $0.outsideReferences }),
  ])
}

extension Command {

  /// 执行这条命令的 Agent 会话（`show`、`live` 共用）：环境变量里第一个有值的。
  static func agentSession(_ call: Call, _ why: String) throws -> String {
    guard let session = callingSession(call) else {
      throw CLIError.invalid("不在 Agent 会话里：\(AgentKind.sessionVariables.joined(separator: "、")) 都没有值。\(why)")
    }
    return session
  }

  static func callingSession(_ call: Call) -> String? {
    AgentKind.sessionVariables.lazy.compactMap { call.environment[$0] }.first { !$0.isEmpty }
  }

  static let show = Command(
    path: ["show"], summary: "把文件发到用户的 CuePad（手机、电脑上都能看）：当前 Agent 会话的对话里出现一张卡片", arguments: "<文件…> --title <标题>…",
    options: [Opt("title", "按文件的先后每个一句，\(PreviewItem.titleRule)", value: "标题")],
    notes: """
      用户在 CuePad 里看这个对话，可能在手机上、也可能在电脑上：在手机上，除了你回答的文字，他只看得到你发的预览和工具结果里的图，本机路径打不开。要他看的东西发过去，回答里说一句发了什么。
      什么时候发：只在要他看一眼或拍板时——做出的页面、文档、方案、界面效果。纯代码改动不发，在回答里说改了什么；不为证明做完了而截图。
      发什么：发真东西，不发它的截图。文档发 .md，要他过目的代码改动发 git diff 存成的 .diff，页面发 .html，还有 PDF、图片、录屏；截图只在要他看界面本身长什么样时发。
      他回复里的 `预览「标题」：……` 说的就是你发的那一份。
      做 HTML 页时按手机上看来做：手机顶栏已显示标题，页面里不写标题、页眉、导语和说明页脚，内容直接开始；按手机宽度排版，跟随深浅色（prefers-color-scheme）；能用原生控件（button、input、select、details）就不自绘；单个文件、不联网，样式与脚本写进同一个 HTML，图片用 data: 地址内联。
      其余命令（灵感、任务、搜索）与在沙箱里怎么运行：cuepad --help。
      会话取 Agent 给每条命令带的环境变量里第一个有值的：\(AgentKind.sessionVariables.joined(separator: "、"))。\(AgentKind.watchedSessionVariable) 是 CuePad 的 Pi 扩展给的、用户在看的会话，子代理发的也落在它的对话里。都没有就报错，不猜。
      一次给几个文件是同一张卡，点开后左右切换；用户看到的是标题，不是文件名。
      可发：\(PreviewKind.supportedList)；单个不超过 \(PreviewItem.maxBytes / 1_000_000) MB。Markdown 排成文稿，diff、patch 是增删对照。
      网页只读、不联网、读不到别的文件；outsideReferences 是页面引用了、预览里因此缺失的地址。经 iCloud 同步，CuePad.app 需要在运行。
      \(Schema.output("[\(PreviewOutput.fields.description("Preview"))]", "kind：\(PreviewKind.allCases.map(\.rawValue).joined(separator: "、"))"))
      """
  ) { call in
    let paths = call.args.positionals
    guard !paths.isEmpty else { throw CLIError.usage("需要至少一个 <文件>") }
    let session = try agentSession(call, "show 只能在 Agent 执行的命令里运行，卡片发到那个会话的对话里")
    let titles = call.args.all("title")
    guard titles.count == paths.count else {
      throw CLIError.usage("\(paths.count) 个文件要 \(paths.count) 个 --title（给了 \(titles.count) 个），按文件的先后每个一句，\(PreviewItem.titleRule)")
    }
    let directory = URL(filePath: call.directory, directoryHint: .isDirectory)
    let urls = paths.map { URL(filePath: $0, relativeTo: directory).standardizedFileURL }
    let added = try await call.store.addPreviews(Array(zip(urls, titles)).map { (url: $0, title: $1) }, sessionID: session)
    var text = "已发到 CuePad：" + added.map { "「\($0.preview.title)」\($0.preview.name)（\($0.preview.byteCount) 字节）" }.joined(separator: "、") + "\n"
    for item in added where !item.outsideReferences.isEmpty {
      text += "注意：\(item.preview.name) 引用的 \(item.outsideReferences.joined(separator: "、")) 在预览里拿不到（只读这一个文件、不联网）；写进同一个文件后再发一次。\n"
    }
    let json: [JSONObject] = added.map { item in
      let preview = item.preview
      return PreviewOutput.fields.json(PreviewOutput(
        id: preview.id.uuidString.lowercased(), session: session, title: preview.title, name: preview.name,
        kind: preview.kind?.rawValue ?? "", bytes: preview.byteCount, outsideReferences: item.outsideReferences))
    }
    return Reply(text: text, json: json)
  }
}
