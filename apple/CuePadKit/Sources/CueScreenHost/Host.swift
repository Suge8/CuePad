#if os(macOS)
import AppKit

/// 这个库经 `DYLD_INSERT_LIBRARIES` 载进正在开发的 Mac 应用（`cuepad live app`）：应用起好后在它里面起一个 `ScreenServer`，
/// 把它自己的窗口变成本机网页（`WindowScreen`）。环境里没有 `CUEPAD_SCREEN_PORT` 的进程里什么都不做。
/// 在进程里做：自己的窗口取画面不过授权、被挡着也出帧，点与键不动真鼠标、不要应用在前台（进程外两样都做不到，实测）。
enum Host {
  static let portKey = "CUEPAD_SCREEN_PORT"
  @MainActor private static var running: (WindowScreen, ScreenServer)?

  /// dyld 载入这个库时跑，在应用的 `main` 之前。
  static func load() {
    guard let port = ProcessInfo.processInfo.environment[portKey].flatMap(UInt16.init) else { return }
    // 这个应用再起的子进程不跟着载：它们会去抢同一个口
    unsetenv(portKey)
    var image = Dl_info()
    if dladdr(#dsohandle, &image) != 0, let inserted = getenv("DYLD_INSERT_LIBRARIES") {
      let others = String(cString: inserted).split(separator: ":").filter { $0 != String(cString: image.dli_fname) }
      if others.isEmpty { unsetenv("DYLD_INSERT_LIBRARIES") } else { setenv("DYLD_INSERT_LIBRARIES", others.joined(separator: ":"), 1) }
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { start(port) }
    }
  }

  @MainActor private static func start(_ port: UInt16) {
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    do {
      let screen = WindowScreen()
      let server = try ScreenServer(source: screen, port: port, identity: "\(getpid())", page: ScreenPage.html(title: name, kind: .desktop))
      running = (screen, server)
      Task {
        do { try await server.start() } catch { say("\(port) 这个口听不上：\(error)") }
      }
    } catch {
      say("\(error)")
    }
  }

  /// 起它的 `cuepad live app` 等不到服务时报"没起来"；原因留在这个应用的 stderr 里。
  static func say(_ message: String) { FileHandle.standardError.write(Data("CuePad 的屏：\(message)\n".utf8)) }
}

@section("__DATA,__mod_init_func") @used
private let load: @convention(c) () -> Void = { Host.load() }
#endif
