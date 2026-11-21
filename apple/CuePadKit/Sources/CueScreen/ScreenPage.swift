#if os(macOS)
/// `ScreenServer` 的那张页：画面收 `/screen` 的 H.264 帧用 `VideoDecoder` 解出来画上去，指针、滚轮、键盘送回去（`ScreenInput`）。
/// 看不见时（预览收起了、切到后台）断开，服务那头就不再取画面；断了每秒重连，连上先来一个关键帧。
/// 底是黑的：画面按比例摆进去后四周多出来的那一圈读作屏的黑边。
/// 脚本分三段、同一个作用域：这里是画面与连接，`hands` 是手指、鼠标与键盘，`mirror` 是画面上那一层看不见的元素。
public enum ScreenPage {
  public enum Kind: Sendable {
    /// 一块触摸屏（模拟器）：指针就是手指，键位原样送进去（打出什么字由它里面的键盘定）。
    /// `tall`：竖长的屏请活预览用手机宽那一档摆（`cuepad-viewport`，App 的 `LivePreview` 读它），画面正好填满，不在宽屏上两边留白。
    case touchscreen(tall: Bool)
    /// 桌面应用的窗口：指针是鼠标。字由看的这一头的输入法组好整段送，功能键与带 ⌘ ⌃ 的照键位送。
    /// 手机上轻点是点一下、拖是滚、按住不动再拖是按着拖，双指捏是放大画面、双指拖是挪；点在输入框上键盘跟着出来、画面凑到那个框上。
    case desktop
  }

  public static func html(title: String, kind: Kind) -> String {
    let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    let (viewport, desktop) = switch kind {
    case .touchscreen(tall: true): (#"<meta name="cuepad-viewport" content="phone">"#, false)
    case .touchscreen: ("", false)
    case .desktop: ("", true)
    }
    return template.replacingOccurrences(of: "{title}", with: escaped).replacingOccurrences(of: "{viewport}", with: viewport)
      .replacingOccurrences(of: "{typing}", with: desktop ? typing : "").replacingOccurrences(of: "{desktop}", with: "\(desktop)")
      .replacingOccurrences(of: "{hands}", with: hands).replacingOccurrences(of: "{mirror}", with: desktop ? mirror : "")
  }

  /// 桌面那一种才有：收字的输入框（平时看不见，输入法组字时露出来）、手机上的两颗钮（放回整幅、叫出键盘）与头一回的那句提示。
  private static let typing = #"""
    <textarea aria-hidden="true" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false"></textarea>
    <nav>
    <button id="whole" aria-label="Fit"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5"/></svg></button>
    <button id="keys" aria-label="Keyboard"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="2.5" y="6" width="19" height="12" rx="2.5"/><path d="M6.5 10h.01M10 10h.01M13.5 10h.01M17 10h.01M8 14h8"/></svg></button>
    </nav>
    <p></p>
    """#

  private static let template = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
    {viewport}
    <title>{title}</title>
    <style>
    html, body { margin: 0; height: 100%; overflow: clip; overscroll-behavior: none; touch-action: none; background: black; }
    /* 手机上让出主屏幕指示条那一截：从画面最下沿往上划是给模拟器的，不让系统当成回自己的主屏幕 */
    body { position: relative; box-sizing: border-box; padding-bottom: env(safe-area-inset-bottom); font: 15px system-ui; }
    figure { position: absolute; left: 0; top: 0; margin: 0; transform-origin: 0 0; outline: none; touch-action: none; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
    canvas { display: block; width: 100%; height: 100%; pointer-events: none; }
    /* 画面上那一层：看不见，只给读页面的（Agent 的快照、点选、旁白）与落点用 */
    section, section * { position: absolute; box-sizing: border-box; margin: 0; padding: 0; border: 0; border-radius: 6px; background: none; color: transparent; caret-color: transparent; font: 1px/1 system-ui;
      overflow: hidden; white-space: nowrap; outline: none; appearance: none; -webkit-appearance: none; resize: none; cursor: default; pointer-events: none; }
    section { inset: 0; }
    section .live { pointer-events: auto; }
    section * { user-select: none; -webkit-user-select: none; }
    /* 表单开着时底下的窗点不动：它铺一层盖住整幅画面（菜单、弹层在它后面，照样压在上头），点底下的元素读页面的就报"被挡住了" */
    section .modal { overflow: visible; }
    section .modal::before { content: ""; position: fixed; inset: 0; pointer-events: auto; }
    section ::placeholder { color: transparent; }
    section ::selection { background: transparent; }
    /* 字号不小于 16px：再小 iOS 聚焦时会把整页放大 */
    body > textarea { position: absolute; left: 50%; bottom: 12px; transform: translateX(-50%); width: 1px; height: 1px; padding: 0; border: 0; opacity: 0; resize: none; outline: none; font: 16px system-ui; white-space: nowrap; overflow: hidden; pointer-events: none; }
    body > textarea.composing { width: 12em; height: 1.5em; padding: 6px 12px; border-radius: 10px; opacity: 1; background: #1c1c1e; color: white; }
    nav { display: none; position: absolute; right: 12px; bottom: calc(12px + env(safe-area-inset-bottom)); gap: 10px; }
    nav button { display: grid; place-items: center; width: 44px; height: 44px; padding: 0; border: 0.5px solid rgba(255, 255, 255, 0.16); border-radius: 22px; color: white;
      background: rgba(30, 30, 32, 0.8); -webkit-backdrop-filter: blur(20px) saturate(1.8); backdrop-filter: blur(20px) saturate(1.8); box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35);
      transition: transform 0.18s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.2s, background 0.2s; -webkit-tap-highlight-color: transparent; }
    nav button:active { transform: scale(0.92); }
    nav button.on { background: rgba(255, 255, 255, 0.92); color: black; }
    #whole { opacity: 0; pointer-events: none; transform: scale(0.8); }
    .zoomed #whole { opacity: 1; pointer-events: auto; transform: none; }
    .zoomed #whole:active { transform: scale(0.92); }
    p { display: none; position: absolute; left: 50%; top: 14px; margin: 0; padding: 8px 14px; border-radius: 18px; transform: translateX(-50%); color: white; background: rgba(30, 30, 32, 0.8);
      -webkit-backdrop-filter: blur(20px) saturate(1.8); backdrop-filter: blur(20px) saturate(1.8); pointer-events: none; opacity: 0; transition: opacity 0.4s; white-space: nowrap; }
    @media (pointer: coarse) { nav { display: flex; } p { display: block; } }
    </style>
    </head>
    <body>
    <figure><canvas></canvas><section></section></figure>
    {typing}
    <script>
    const desktop = {desktop};
    const stage = document.querySelector("figure"), canvas = stage.querySelector("canvas"), context = canvas.getContext("2d");
    const field = document.querySelector("textarea"), board = field ?? stage;
    if (!desktop) stage.tabIndex = 0;
    let socket, decoder, configured = "";

    // 画面摆在哪：先按比例整幅摆进页面（键盘弹出来时不跟着缩：照没有键盘时的高算），再照 `view` 放大、挪（手机上的双指，见 hands）。
    // 放大后不留空边：比页面大的那个方向贴着边，小的那个方向居中。`smooth`：这一下不是手指带着的，滑过去
    const view = { zoom: 1, x: 0, y: 0 };
    let wide = 0, tall = 0;
    const room = () => ({ width: document.body.clientWidth, height: document.body.clientHeight - parseFloat(getComputedStyle(document.body).paddingBottom) });
    const settle = smooth => {
      const { width, height } = room();
      if (width !== wide) [wide, tall] = [width, 0];
      tall = Math.max(tall, height);
      const scale = Math.min(width / canvas.width, tall / canvas.height), zoomed = { width: canvas.width * scale * view.zoom, height: canvas.height * scale * view.zoom };
      view.x = zoomed.width <= width ? (width - zoomed.width) / 2 : Math.min(0, Math.max(width - zoomed.width, view.x));
      view.y = zoomed.height <= height ? (height - zoomed.height) / 2 : Math.min(0, Math.max(height - zoomed.height, view.y));
      Object.assign(stage.style, { width: canvas.width * scale + "px", height: canvas.height * scale + "px", transition: smooth ? "transform 0.32s cubic-bezier(0.2, 0.8, 0.2, 1)" : "none",
        transform: `translate(${view.x}px, ${view.y}px) scale(${view.zoom})` });
      document.body.classList.toggle("zoomed", view.zoom > 1.01);
    };
    addEventListener("resize", () => settle());

    const paint = frame => {
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
        settle();
      }
      context.drawImage(frame, 0, 0);
      frame.close();
      look?.(false);
    };

    const configure = text => {
      if (text === configured && decoder.state === "configured") return;
      const { codec, description } = JSON.parse(text);
      if (decoder && decoder.state !== "closed") decoder.close();
      decoder = new VideoDecoder({ output: paint, error: () => socket.close() });
      decoder.configure({ codec, description: Uint8Array.from(atob(description), c => c.charCodeAt(0)), optimizeForLatency: true });
      configured = text;
    };

    // 画面里有什么（mirror 那一段）：`look(true)` 是刚送了输入、这就去问，`look(false)` 是画面自己动了、隔一会儿问一次
    let look = null;
    const say = message => {
      if (socket?.readyState !== WebSocket.OPEN) return;
      socket.send(JSON.stringify(message));
      look?.(true);
    };
    const place = event => {
      const box = stage.getBoundingClientRect();
      return { x: (event.clientX - box.left) / box.width, y: (event.clientY - box.top) / box.height, width: box.width, height: box.height };
    };
    const inside = ({ x, y }) => x >= 0 && x <= 1 && y >= 0 && y <= 1;
    const clamp = value => Math.min(1, Math.max(0, value));
    const point = at => ({ x: clamp(at.x), y: clamp(at.y) });
    {hands}
    {mirror}
    const connect = () => {
      if (document.hidden || socket) return;
      const mine = socket = new WebSocket(`ws://${location.host}/screen`);
      mine.binaryType = "arraybuffer";
      mine.onmessage = ({ data }) => {
        if (typeof data === "string") return configure(data);
        const bytes = new Uint8Array(data);
        decoder.decode(new EncodedVideoChunk({ type: bytes[0] ? "key" : "delta", timestamp: performance.now() * 1000, data: bytes.subarray(1) }));
      };
      mine.onclose = () => {
        if (socket === mine) socket = null;
        // 按着的手指与键服务那头替这条连接抬起了：这头也忘掉，重连后不接着发半截的拖动
        release();
        setTimeout(connect, 1000);
      };
    };
    document.addEventListener("visibilitychange", () => document.hidden ? socket?.close() : connect());
    connect();
    </script>
    </body>
    </html>
    """#
}
#endif
