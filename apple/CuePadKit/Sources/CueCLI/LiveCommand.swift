import CueStore
import Foundation

private struct LiveOutput {
  let session: String
  let url: String
  let found: Bool
  static let fields = OutputFields<LiveOutput>(fields: [("session", { $0.session }), ("url", { $0.url }), ("found", { $0.found })])
}

extension Command {
  static let live = Command(
    path: ["live"], summary: "在用户 Mac 上的 CuePad 里打开活预览：你在本机起的网页服务，开在这个会话旁边", arguments: "[地址或端口]",
    notes: """
      什么时候用：你在本机起了网页的开发服务（vite、next dev 之类）、要用户看这个页面时。预览是活的，热更新照常，改完不用再发；要他看的是一份文件就用 show。
      不给参数：用 CuePad 认出的这个会话的服务——本机在监听、回 HTML，进程是这个会话 Agent 的后代，或工作目录在会话的工作目录里（nohup 甩到后台、进程树断了的靠这一条）；认出几个取最近起来的，之后服务换了端口预览跟过去。认不出就报错，这时给端口。
      给参数：5173 是 http://localhost:5173；也可写地址，如 localhost:3000/admin、http://127.0.0.1:8080。给了的不跟着换端口。
      开在哪：这个会话此刻开在 CuePad 主区、右半空着时，预览直接滑开；否则不动他的排布，会话栏头的预览钮亮起，他点了才开。只开在 Mac 上，手机上看不到活预览：别在回答里说发到了手机，要手机上也能看就用 show 发 HTML 文件。
      会话同 show：取 Agent 给每条命令带的环境变量里第一个有值的（\(sessionVariables.joined(separator: "、"))），都没有就报错。
      这台 Mac 上没有开着这份资料库的 CuePad.app 时报错退出（退出码 1），不交出去：请用户打开 CuePad 后再运行。
      \(Schema.output(LiveOutput.fields.description("Live"), "found：地址是认出来的（没给参数）"))
      """
  ) { call in
    let session = try agentSession(call, "live 只能在 Agent 执行的命令里运行，预览开在那个会话旁边")
    let given = call.args.positionals
    guard given.count <= 1 else { throw CLIError.usage("最多一个地址或端口（给了 \(given.count) 个）") }
    let url: URL
    if let text = given.first {
      guard let parsed = LiveAddress.url(from: text) else { throw CLIError.usage("「\(text)」不是能打开的网页地址：给端口（1–65535，如 5173）或 http(s) 地址（localhost:3000/admin）") }
      url = parsed
    } else {
      var servers = LiveServers()
      guard let first = await servers.find(for: try await call.store.liveOwner(session)).first else {
        throw CLIError.invalid(
          "没认出这个会话起的网页服务（本机在监听、回 HTML，进程是这个会话 Agent 的后代或工作目录在会话的工作目录里）。还没起来就等它起来再运行；起在别处就给端口：cuepad live 5173")
      }
      url = first
    }
    let found = given.isEmpty
    guard call.store.appIsOpen else {
      throw CLIError.invalid("这台 Mac 上的 CuePad 没开（没有 App 开着资料库 \(UserHome.shown(call.store.databasePath))）：没有交出去。请用户打开 CuePad 后再运行 cuepad live")
    }
    try await call.store.sendLive(url, to: session, found: found)
    let shown = LiveAddress.shown(url)
    let text = "已交给这台 Mac 上的 CuePad：\(shown)。会话开在主区、右半空着时预览直接滑开；否则会话栏头的预览钮亮起，等用户点开。手机上看不到活预览。\n"
    return Reply(text: text, json: LiveOutput.fields.json(LiveOutput(session: session, url: url.absoluteString, found: found)))
  }
}
