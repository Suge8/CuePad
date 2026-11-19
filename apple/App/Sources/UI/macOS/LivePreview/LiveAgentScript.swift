#if os(macOS)
import WebKit

/// Agent 操作活预览的两段注入脚本，开页时注入每一个框（跨域的 iframe 也注入）。
/// `agent` 在自己的内容世界里：页面读不到、改不了引用表，DOM 共用；`hooks` 在页面的世界里包住控制台与请求，经消息送回原生（`LivePageRecord`）。
/// 包住 `console.*` 的代价：Safari 网页检查器里这些输出的出处显示成这段脚本。
enum LiveAgentScript {
    static let world = WKContentWorld.world(name: "cuepad-agent")

    static let hooks = #"""
    (() => {
      const post = (level, text, source) => {
        try { webkit.messageHandlers.cuepadLog.postMessage({ level, text: String(text).slice(0, 2000), source: source ?? null, page: location.href }); } catch {}
      };
      const show = value => {
        if (value instanceof Error) return value.stack ? `${value.name}: ${value.message}\n${value.stack.split("\n").slice(0, 4).join("\n")}` : `${value.name}: ${value.message}`;
        if (typeof value === "object" && value !== null) { try { return JSON.stringify(value); } catch { return String(value); } }
        return String(value);
      };
      for (const level of ["error", "warn", "log", "info", "debug"]) {
        const original = console[level];
        console[level] = function (...args) { post(level, args.map(show).join(" ")); return original.apply(this, args); };
      }
      addEventListener("error", event => {
        const node = event.target;
        if (node && node !== window && node.tagName) post("network", `载不出 <${node.tagName.toLowerCase()}> ${node.currentSrc || node.src || node.href || ""}`);
        else post("error", `未捕获：${event.error ? show(event.error) : event.message}`, event.filename ? `${event.filename}:${event.lineno}:${event.colno}` : null);
      }, true);
      addEventListener("unhandledrejection", event => post("error", `未处理的 Promise 拒绝：${show(event.reason)}`));
      addEventListener("securitypolicyviolation", event => post("error", `CSP 拦下了 ${event.blockedURI || "内联脚本"}（${event.violatedDirective}）`));
      const pending = delta => { try { webkit.messageHandlers.cuepadLog.postMessage({ level: "pending", text: String(delta) }); } catch {} };
      const originalFetch = window.fetch;
      window.fetch = async function (input, init) {
        const url = typeof input === "string" ? input : input?.url ?? String(input);
        const method = (init?.method ?? input?.method ?? "GET").toUpperCase();
        pending(1);
        try {
          const response = await originalFetch.apply(this, arguments);
          if (response.status >= 400) post("network", `${method} ${url} → ${response.status} ${response.statusText}`.trim());
          return response;
        } catch (error) {
          if (error?.name !== "AbortError") post("network", `${method} ${url} → 失败：${error?.message ?? error}`);
          throw error;
        } finally {
          pending(-1);
        }
      };
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) { this.__cuepad = `${String(method).toUpperCase()} ${url}`; return open.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        pending(1);
        this.addEventListener("loadend", () => {
          pending(-1);
          if (this.status >= 400) post("network", `${this.__cuepad} → ${this.status}`);
          else if (this.status === 0) post("network", `${this.__cuepad} → 失败`);
        });
        return send.apply(this, arguments);
      };
    })();
    """#

    /// 引用是数字（原生端拼上页面代号成了 `a5`）：同一份文档里元素活着编号就不变；元素被重绘替换、上次快照里它的"角色 + 名称"独一份时，新元素接过这个编号。
    /// 编号从原生给的 `seed` 往后发：一页里主框与各个框共用一串数，引用不用带框号。
    static let agent = "(() => {\n" + reading + "\n" + acting + "\n})();"

    /// 点、填、按与高亮：接在 `reading` 后面，同一个作用域。
    private static let acting = #"""
      // 与快照里那一行同一个说法
      const describe = el => {
        const role = roleOf(el);
        const name = role && role !== "generic" ? nameOf(el, role) : textOf(el);
        return (role && role !== "presentation" && role !== "none" ? role : "generic") + (name ? " " + quote(name) : "");
      };

      // 高亮与点选同一套画法（`LivePick.ring`、`LivePick.tag`）：一圈框加框外的标签，约 1 秒后淡掉；截图前清掉
      const mark = (el, word, tint, ink) => {
        const rect = el.getBoundingClientRect();
        const pad = \#(LivePick.pad), gap = \#(LivePick.gap);
        const radius = parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0;
        const layer = document.createElement("div");
        layer.setAttribute("data-cuepad-mark", "");
        layer.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647;transition:opacity .3s";
        const box = document.createElement("div");
        box.style.cssText = `\#(LivePick.ring)`;
        Object.assign(box.style, { left: rect.left - pad + "px", top: rect.top - pad + "px", width: rect.width + 2 * pad + "px", height: rect.height + 2 * pad + "px", borderRadius: radius + pad + "px" });
        const label = document.createElement("div");
        label.style.cssText = `\#(LivePick.tag)`;
        label.textContent = word;
        layer.append(box, label);
        document.documentElement.append(layer);
        const height = label.offsetHeight, above = rect.top - pad - gap - height;
        label.style.top = (above >= gap ? above : Math.min(rect.bottom + pad + gap, innerHeight - height - gap)) + "px";
        label.style.left = Math.max(gap, Math.min(rect.left - pad, innerWidth - label.offsetWidth - gap)) + "px";
        // 窗口被挡住、预览收着时 WebKit 停掉页面动画：淡出停住也照样按时拿掉
        setTimeout(() => { layer.style.opacity = 0; }, 800);
        setTimeout(() => layer.remove(), 1200);
      };
      const clearMarks = () => document.querySelectorAll("[data-cuepad-mark]").forEach(node => node.remove());

      const topmost = (el, x, y) => {
        const root = el.getRootNode();
        let hit = (root.elementFromPoint ? root : document).elementFromPoint(x, y);
        while (hit?.shadowRoot && hit !== el) { const inner = hit.shadowRoot.elementFromPoint(x, y); if (!inner || inner === hit) break; hit = inner; }
        return hit;
      };
      const reachable = el => {
        el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        if (el.disabled || el.getAttribute("aria-disabled") === "true") throw new Error(`${describe(el)} 是禁用的，点不了`);
        const rect = el.getBoundingClientRect();
        if (!rect.width || !rect.height) throw new Error(`${describe(el)} 没有大小，点不到`);
        const x = Math.min(Math.max(rect.left + rect.width / 2, 1), innerWidth - 1), y = Math.min(Math.max(rect.top + rect.height / 2, 1), innerHeight - 1);
        const hit = topmost(el, x, y);
        if (hit && !el.contains(hit) && !hit.contains(el) && !(el.labels && [...el.labels].some(label => label.contains(hit)))) {
          const blocker = hit.localName + (hit.id ? "#" + hit.id : hit.classList[0] ? "." + hit.classList[0] : "");
          throw new Error(`${describe(el)} 被 <${blocker}> 挡住了，点不到：先关掉挡着的（弹层、遮罩），或等它消失`);
        }
        return { x, y };
      };

      // 原生点击之前先挂上听的：真实的按下到没到（没到说明原生事件没进这份文档，可以放心退回合成点击）、点击是不是落在这个元素上。
      // 原生事件在网页进程里排队派发，可能比问结果的这一句晚到：等到松开那一下再答，最多 1 秒
      let armed = null;
      const arm = ({ n }) => {
        const el = resolve(n);
        const { x, y } = reachable(el);
        const state = { el, down: null, clicked: false, up: false };
        const listen = event => {
          if (!event.isTrusted) return;
          if (event.type === "mousedown") state.down = event.composedPath()[0] ?? event.target;
          if (event.type === "click" && event.composedPath().includes(el)) state.clicked = true;
          if (event.type === "click" || event.type === "mouseup") state.up = true;
        };
        for (const type of ["mousedown", "mouseup", "click"]) addEventListener(type, listen, true);
        armed = { state, listen };
        return { x, y, did: describe(el) };
      };
      const disarm = async () => {
        if (!armed) return { seen: false, got: false };
        const { state, listen } = armed;
        for (let i = 0; i < 50 && !(state.up && (state.clicked || i > 2)); i++) await new Promise(done => setTimeout(done, 20));
        for (const type of ["mousedown", "mouseup", "click"]) removeEventListener(type, listen, true);
        armed = null;
        const where = state.down instanceof Element ? state.down.localName + (state.down.id ? "#" + state.down.id : "") : null;
        return { seen: state.down !== null, got: state.clicked, where };
      };

      const click = ({ n }) => {
        const el = resolve(n);
        const { x, y } = reachable(el);
        const init = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0, view: window };
        const pointer = { ...init, pointerId: 1, pointerType: "mouse", isPrimary: true };
        el.dispatchEvent(new PointerEvent("pointerover", pointer));
        el.dispatchEvent(new MouseEvent("mouseover", init));
        el.dispatchEvent(new PointerEvent("pointermove", pointer));
        el.dispatchEvent(new MouseEvent("mousemove", init));
        el.dispatchEvent(new PointerEvent("pointerdown", { ...pointer, buttons: 1 }));
        const down = el.dispatchEvent(new MouseEvent("mousedown", { ...init, buttons: 1 }));
        if (down) (el.closest("button, a, input, select, textarea, [tabindex], [contenteditable]") ?? el).focus?.({ preventScroll: true });
        el.dispatchEvent(new PointerEvent("pointerup", pointer));
        el.dispatchEvent(new MouseEvent("mouseup", init));
        el.click();
        return { did: describe(el) };
      };

      const fill = ({ n, text }) => {
        const el = resolve(n);
        el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        if (el.disabled || el.getAttribute("aria-disabled") === "true") throw new Error(`${describe(el)} 是禁用的，填不了`);
        if (el.readOnly) throw new Error(`${describe(el)} 是只读的，填不了`);
        if (el.localName === "select") {
          const option = [...el.options].find(o => o.value === text || o.label === text || o.text.trim() === text);
          if (!option) throw new Error(`${describe(el)} 没有「${text}」这一项，可选：${[...el.options].map(o => o.label).join("、")}`);
          el.focus({ preventScroll: true });
          el.value = option.value;
          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return { did: `${describe(el)} 选了「${option.label}」`, chose: true };
        }
        if (el.localName === "input" && ["checkbox", "radio", "file", "submit", "button", "reset", "image", "range", "color"].includes(el.type)) {
          throw new Error(`${describe(el)} 不是能填字的输入框：${el.type === "file" ? "用 cuepad live upload" : "用 cuepad live click"}`);
        }
        if (!el.isContentEditable && !("value" in el && (el.localName === "input" || el.localName === "textarea"))) throw new Error(`${describe(el)} 不是输入框`);
        el.focus({ preventScroll: true });
        if (el.isContentEditable) document.getSelection().selectAllChildren(el);
        else el.select?.();
        // execCommand 走浏览器自己的编辑：beforeinput、input 的 isTrusted 为真，React 的受控输入跟着更新；有的输入类型（email、number）不让选中，退回直接改值
        const edited = text ? document.execCommand("insertText", false, text) : document.execCommand("delete");
        const now = () => el.isContentEditable ? el.innerText.replace(/\n$/, "") : el.value;
        if (!edited || now() !== text) {
          const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), "value")?.set;
          if (el.isContentEditable) el.textContent = text; else if (setter) setter.call(el, text); else el.value = text;
          el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
        }
        el.dispatchEvent(new Event("change", { bubbles: true }));
        const value = now();
        const shown = el.type === "password" ? `${value.length} 个字符` : quote(clip(value, 80));
        return { did: `${describe(el)} 填成了 ${shown}` };
      };

      const focusable = () => [...document.querySelectorAll("a[href], button, input, select, textarea, [tabindex], [contenteditable]")]
        .filter(node => node.tabIndex >= 0 && !node.disabled && node.checkVisibility());
      const press = ({ n, key }) => {
        const el = n !== null ? resolve(n) : (document.activeElement ?? document.body);
        if (n !== null) el.focus({ preventScroll: true });
        const codes = { Enter: "Enter", Tab: "Tab", Escape: "Escape", Backspace: "Backspace", " ": "Space" };
        const code = codes[key] ?? (key.length === 1 ? (/[a-z]/i.test(key) ? "Key" + key.toUpperCase() : /\d/.test(key) ? "Digit" + key : "") : key);
        const init = { key, code, bubbles: true, cancelable: true, composed: true, view: window };
        const go = el.dispatchEvent(new KeyboardEvent("keydown", init));
        let effect = "";
        if (go) {
          const editable = el.isContentEditable || (["input", "textarea"].includes(el.localName) && "value" in el);
          if (key === "Enter" && el.localName === "input" && el.form) { el.form.requestSubmit(); effect = "，提交了表单"; }
          else if (key === "Enter" && el.localName === "textarea") { document.execCommand("insertText", false, "\n"); }
          else if (key === "Enter" && (el.localName === "button" || el.localName === "a" || roleOf(el) === "button" || roleOf(el) === "link")) { el.click(); effect = "，点了它"; }
          else if (key === "Tab") {
            const all = focusable();
            all[(all.indexOf(el) + 1) % all.length]?.focus();
            effect = `，焦点到了 ${document.activeElement && document.activeElement !== document.body ? describe(document.activeElement) : "页面"}`;
          } else if (key === "Backspace" && editable) document.execCommand("delete");
          else if (key.length === 1 && editable) {
            el.dispatchEvent(new KeyboardEvent("keypress", init));
            document.execCommand("insertText", false, key);
          }
        }
        el.dispatchEvent(new KeyboardEvent("keyup", init));
        return { did: `在 ${describe(el)} 上按了 ${key}${go ? effect : "（页面拦下了默认动作）"}`, mark: n !== null };
      };

      const has = ({ text, selector }) => {
        if (selector) return [...document.querySelectorAll(selector)].some(el => el.checkVisibility());
        if ((document.body?.innerText ?? "").includes(text)) return true;
        const walker = document.createTreeWalker(document.documentElement, NodeFilter.SHOW_ELEMENT);
        for (let node = walker.currentNode; node; node = walker.nextNode()) if (node.shadowRoot?.textContent?.includes(text)) return true;
        return false;
      };

      const rect = ({ n }) => {
        const el = resolve(n);
        el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        const box = el.getBoundingClientRect();
        return { x: box.left, y: box.top, width: box.width, height: box.height };
      };

      // 框在这一页里的内容区左上角（边框、内边距之内）；看不见的框报错
      const frameBox = ({ n }) => {
        const el = resolve(n);
        el.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "instant" });
        const box = el.getBoundingClientRect(), style = getComputedStyle(el);
        if (!box.width || !box.height) throw new Error("这个框看不见");
        return { x: box.left + el.clientLeft + parseFloat(style.paddingLeft), y: box.top + el.clientTop + parseFloat(style.paddingTop) };
      };
      const hitsFrame = ({ n, x, y }) => topmost(resolve(n), x, y) === resolve(n);

      const chooseFile = ({ n }) => {
        const el = resolve(n);
        if (el.localName !== "input" || el.type !== "file") throw new Error(`${describe(el)} 不是文件框（快照里带 [file] 的那个才是）`);
        reachable(el);
        el.click();
        return { did: describe(el), multiple: el.multiple };
      };
      const files = ({ n }) => [...resolve(n).files].map(file => file.name);

      const markRef = ({ n, word, tint, ink }) => { mark(resolve(n), word, tint, ink); return true; };

      globalThis.cue = { token, snapshot, click, arm, disarm, fill, press, has, rect, frameBox, hitsFrame, chooseFile, files, markRef, clearMarks };
      try { webkit.messageHandlers.cuepadAgent.postMessage({ hello: token, url: location.href, main: window === top }); } catch {}
    """#
}
#endif
