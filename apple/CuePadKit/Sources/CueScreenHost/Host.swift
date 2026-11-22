#if os(macOS)
import AppKit

/// 这个库经 `DYLD_INSERT_LIBRARIES` 载进正在开发的 Mac 应用（`cuepad live app`）：应用起好后在它里面起一个 `ScreenServer`，
/// 把它自己的窗口变成本机网页（`WindowScreen`）。环境里没有 `CUEPAD_SCREEN_PORT` 的进程里什么都不做。
/// `CUEPAD_SCREEN_OWNER`（起它的那个会话）写进服务的身份里：`cuepad live app` 再起时只退自己会话起的那一份。
/// 在进程里做：自己的窗口取画面不过授权、被挡着也出帧，点与键不动真鼠标、不要应用在前台（进程外两样都做不到，实测）。
enum Host {
  static let portKey = "CUEPAD_SCREEN_PORT"
  static let ownerKey = "CUEPAD_SCREEN_OWNER"
  @MainActor private static var running: (WindowScreen, ScreenServer)?

  static func load() {
    guard let port = ProcessInfo.processInfo.environment[portKey].flatMap(UInt16.init) else { return }
    let owner = ProcessInfo.processInfo.environment[ownerKey] ?? ""
    unsetenv(portKey)
    unsetenv(ownerKey)
    var image = Dl_info()
    if dladdr(#dsohandle, &image) != 0, let inserted = getenv("DYLD_INSERT_LIBRARIES") {
      let others = String(cString: inserted).split(separator: ":").filter { $0 != String(cString: image.dli_fname) }
      if others.isEmpty { unsetenv("DYLD_INSERT_LIBRARIES") } else { setenv("DYLD_INSERT_LIBRARIES", others.joined(separator: ":"), 1) }
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { start(port, owner: owner) }
    }
  }

  @MainActor private static func start(_ port: UInt16, owner: String) {
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    do {
      let screen = WindowScreen()
      let server = try ScreenServer(source: screen, port: port, identity: "\(getpid()) \(owner)", page: ScreenPage.html(title: name, kind: .desktop))
      running = (screen, server)
      Task {
        do { try await server.start() } catch { say("\(port) 这个口听不上：\(error)") }
      }
    } catch {
      say("\(error)")
    }
  }

  static func say(_ message: String) { FileHandle.standardError.write(Data("CuePad 的屏：\(message)\n".utf8)) }
}

@section("__DATA,__mod_init_func") @used
private let load: @convention(c) () -> Void = { Host.load() }
#endif
