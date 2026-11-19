#if os(macOS)
extension LiveAgentScript {
    /// 认角色与名称、出快照、按编号找回元素。
    static let reading = #"""
      const token = crypto.randomUUID();
      const numOf = new WeakMap(), byNum = new Map();
      let counter = 0, uniqueKeys = new Set();
      const INTERACTIVE = new Set(["link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "option", "slider",
        "spinbutton", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "treeitem"]);
      const FROM_CONTENT = new Set(["link", "button", "heading", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "cell",
        "columnheader", "rowheader", "treeitem", "tooltip", "switch", "checkbox", "radio"]);
      const LEAF = new Set(["textbox", "searchbox", "checkbox", "radio", "img", "slider", "spinbutton", "combobox", "switch", "progressbar", "separator"]);
      const SKIP = new Set(["script", "style", "noscript", "template", "head", "meta", "link"]);
      const clip = (text, max = 160) => { text = (text ?? "").replace(/\s+/g, " ").trim(); return text.length > max ? text.slice(0, max - 1) + "…" : text; };
      const quote = text => JSON.stringify(text);

      const implicitRole = el => {
        const tag = el.localName;
        switch (tag) {
          case "a": case "area": return el.hasAttribute("href") ? "link" : null;
          case "button": case "summary": return "button";
          case "select": return el.multiple || el.size > 1 ? "listbox" : "combobox";
          case "textarea": return "textbox";
          case "option": return "option";
          case "img": return el.getAttribute("alt") === "" ? null : "img";
          case "svg": return el.getAttribute("aria-label") || el.querySelector(":scope > title") ? "img" : null;
          case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
          case "nav": return "navigation";
          case "main": return "main";
          case "aside": return "complementary";
          case "header": return el.closest("article, section, main, aside, nav") ? null : "banner";
          case "footer": return el.closest("article, section, main, aside, nav") ? null : "contentinfo";
          case "form": return "form";
          case "section": return el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") ? "region" : null;
          case "dialog": return "dialog";
          case "ul": case "ol": case "menu": return "list";
          case "li": return "listitem";
          case "table": return "table";
          case "tr": return "row";
          case "td": return "cell";
          case "th": return el.getAttribute("scope") === "row" ? "rowheader" : "columnheader";
          case "progress": return "progressbar";
          case "hr": return "separator";
          case "iframe": case "frame": return "iframe";
          case "fieldset": return "group";
          case "input": {
            const type = (el.getAttribute("type") || "text").toLowerCase();
            if (type === "hidden") return null;
            if (["button", "submit", "reset", "image", "file"].includes(type)) return "button";
            if (type === "checkbox") return el.getAttribute("role") === "switch" ? "switch" : "checkbox";
            if (type === "radio") return "radio";
            if (type === "range") return "slider";
            if (type === "number") return "spinbutton";
            if (type === "search") return "searchbox";
            return "textbox";
          }
        }
        if (el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable)) return "textbox";
        return null;
      };
      const roleOf = el => (el.getAttribute("role") || "").split(/\s+/)[0] || implicitRole(el);

      const textOf = el => clip(el.innerText ?? el.textContent ?? "");
      // 只有图标的按钮：名字在里面的 img alt、svg 的 title、带 aria-label 的子元素上
      const innerLabel = el => {
        const labelled = el.querySelector("[aria-label], img[alt], svg title");
        return clip(labelled?.getAttribute?.("aria-label") || labelled?.getAttribute?.("alt") || labelled?.textContent || "");
      };
      const nameOf = (el, role) => {
        const root = el.getRootNode();
        const by = el.getAttribute("aria-labelledby");
        if (by) { const text = by.split(/\s+/).map(id => root.getElementById?.(id)?.textContent ?? "").join(" "); if (text.trim()) return clip(text); }
        const label = el.getAttribute("aria-label");
        if (label?.trim()) return clip(label);
        if (el.labels?.length) { const text = [...el.labels].map(node => node.innerText).join(" "); if (text.trim()) return clip(text); }
        if (el.localName === "input" && ["button", "submit", "reset"].includes(el.type)) return clip(el.value || (el.type === "submit" ? "Submit" : ""));
        if (el.localName === "input" && el.type === "file") return clip(el.title || "");
        if (el.localName === "img" || (el.localName === "input" && el.type === "image")) return clip(el.alt || el.title || "");
        if (el.localName === "svg") return clip(el.querySelector(":scope > title")?.textContent ?? "");
        if (el.localName === "iframe") return clip(el.title || el.name || "");
        if (el.localName === "fieldset") return clip(el.querySelector(":scope > legend")?.innerText ?? "");
        if (FROM_CONTENT.has(role)) return textOf(el) || innerLabel(el) || clip(el.title || "");
        return clip(el.placeholder || el.title || "");
      };

      const hidden = el => el.getAttribute("aria-hidden") === "true" || el.hidden || !el.checkVisibility({ visibilityProperty: true });
      const clickable = el => {
        if (el.hasAttribute("onclick") || el.tabIndex >= 0 && el.hasAttribute("tabindex")) return true;
        if (getComputedStyle(el).cursor !== "pointer") return false;
        const parent = el.parentElement;
        return !parent || getComputedStyle(parent).cursor !== "pointer";
      };
      const childrenOf = node => {
        if (node.shadowRoot) return [...node.shadowRoot.childNodes];
        if (node.localName === "slot") { const assigned = node.assignedNodes({ flatten: true }); return assigned.length ? assigned : [...node.childNodes]; }
        return [...node.childNodes];
      };
      const alive = el => el && el.isConnected && el.ownerDocument === document;

      const numFor = (el, role, name) => {
        let n = numOf.get(el);
        if (n === undefined) {
          const key = role + "\u0000" + name;
          // 重绘换掉的元素：上一份快照里同角色同名的只有一个、而且已经不在了，新元素接过它的编号
          if (name && uniqueKeys.has(key)) {
            for (const [old, entry] of byNum) if (entry.key === key && !alive(entry.ref.deref())) { n = old; break; }
          }
          if (n === undefined) n = ++counter;
          numOf.set(el, n);
        }
        byNum.set(n, { ref: new WeakRef(el), key: role + "\u0000" + name });
        return n;
      };

      // 每行：缩进两格一层；`\u0000frame <编号> <地址>` 是 iframe 的占位，原生端接上框里的那一份
      const snapshot = ({ seed = 0, code = "", root = null, interactive = false } = {}) => {
        counter = Math.max(counter, seed);
        const lines = [], keys = new Map(), issued = [];
        // -i 不要结构：一行一个，框里的那几行缩一格接在框下
        const emit = (depth, line) => lines.push("  ".repeat(interactive ? 0 : depth) + line);
        const walk = (nodes, depth, shared) => {
          const acc = shared ?? { text: "" };
          const flush = () => { const text = clip(acc.text, 200); if (text && !interactive) emit(depth, "- text: " + quote(text)); acc.text = ""; };
          for (const child of nodes) {
            if (child.nodeType === Node.TEXT_NODE) { acc.text += child.textContent; continue; }
            if (child.nodeType !== Node.ELEMENT_NODE || SKIP.has(child.localName) || child.hasAttribute("data-cuepad-mark")) continue;
            if (child.localName !== "slot" && hidden(child)) continue;
            const role = roleOf(child);
            const actionable = INTERACTIVE.has(role) || (role !== "presentation" && role !== "none" && clickable(child));
            const frame = child.localName === "iframe" || child.localName === "frame";
            if (!actionable && !frame && (!role || role === "presentation" || role === "none" || role === "generic")) {
              const display = child.localName === "slot" ? "contents" : getComputedStyle(child).display;
              const inline = display === "inline" || display === "contents";
              if (!inline) flush();
              // 关联了控件的 label：它的字已是控件的名字，不再单列一行
              if (child.localName === "label" && child.control) { const hold = acc.text; walk(childrenOf(child), depth, acc); acc.text = hold; }
              else walk(childrenOf(child), depth, acc);
              if (!inline) flush();
              continue;
            }
            flush();
            const nested = child.querySelector("a[href], button, input, select, textarea, iframe, [role=button], [role=link], [tabindex], h1, h2, h3, h4, h5, h6");
            // 名字取自内容、里面又有要单列的元素时不取：内容在子行里已有，取了整块的字会重复一遍
            const fromContent = !role || role === "generic" || FROM_CONTENT.has(role) && !child.getAttribute("aria-label") && !child.getAttribute("aria-labelledby");
            const name = fromContent && nested ? "" : role && role !== "generic" ? nameOf(child, role) : textOf(child);
            const shownRole = role && role !== "presentation" && role !== "none" ? role : "generic";
            let line = "- " + shownRole + (name ? " " + quote(name) : "");
            if (role === "heading") line += ` [level=${child.getAttribute("aria-level") || child.localName.slice(1) || 2}]`;
            if (child.checked === true || child.getAttribute("aria-checked") === "true") line += " [checked]";
            if (child.disabled || child.getAttribute("aria-disabled") === "true") line += " [disabled]";
            if (child.getAttribute("aria-expanded")) line += ` [expanded=${child.getAttribute("aria-expanded")}]`;
            if (child.getAttribute("aria-selected") === "true") line += " [selected]";
            if (child.required) line += " [required]";
            if (child.getAttribute("aria-invalid") === "true") line += " [invalid]";
            if (child.localName === "input" && child.type === "password") line += " [password]";
            if (child.localName === "input" && child.type === "file") line += " [file]";
            if (child === document.activeElement) line += " [focused]";
            if (actionable || frame) {
              const n = numFor(child, shownRole, name);
              issued.push(n);
              if (actionable) { const key = shownRole + "\u0000" + name; keys.set(key, (keys.get(key) ?? 0) + 1); }
              line += ` [ref=${code}${n}]`;
              if (!INTERACTIVE.has(role) && actionable) line += " [cursor=pointer]";
            }
            if (frame) {
              emit(depth, line + ":");
              lines.push("  ".repeat(interactive ? 1 : depth + 1) + "\u0000frame " + numOf.get(child) + " " + (child.src || "about:blank"));
              continue;
            }
            let value = null;
            if (child.localName === "select") value = [...child.selectedOptions].map(option => option.label).join(", ");
            else if (["textbox", "searchbox", "spinbutton", "slider", "combobox"].includes(role) && child.type !== "password") value = child.isContentEditable ? child.innerText : child.value;
            if (value) { if (actionable || !interactive) emit(depth, line + ": " + quote(clip(value, 200))); continue; }
            if (LEAF.has(role) || ((FROM_CONTENT.has(role) || !role || role === "generic") && !nested)) {
              if (actionable || !interactive) emit(depth, line);
              continue;
            }
            const before = lines.length;
            if (actionable || !interactive) emit(depth, line + ":");
            walk(childrenOf(child), depth + 1);
            // 没有名字、不能操作、里面也没东西的结构行（空的 row、listitem）不留
            if (!interactive && lines.length === before + 1) { if (!name && !actionable) lines.pop(); else lines[before] = lines[before].slice(0, -1); }
            if (interactive && actionable && lines.length === before + 1) lines[before] = lines[before].slice(0, -1);
          }
          if (!shared) flush();
        };
        const start = root === null ? (document.body ?? document.documentElement) : resolve(root);
        walk(root === null ? childrenOf(start) : [start], 0);
        // 只读一块时数不全，"独一份"只按整页的算
        if (root === null) uniqueKeys = new Set([...keys].filter(([, count]) => count === 1).map(([key]) => key));
        return { token, title: document.title, url: location.href, lines, counter, issued };
      };

      const resolve = n => {
        const el = byNum.get(n)?.ref.deref();
        if (alive(el)) return el;
        const entry = byNum.get(n);
        // 快照之后才被重绘换掉：同角色同名的此刻也只有一个，就是它
        if (entry && uniqueKeys.has(entry.key)) {
          const [role, name] = entry.key.split("\u0000");
          const found = [];
          const visit = node => {
            for (const child of childrenOf(node)) {
              if (child.nodeType !== Node.ELEMENT_NODE) continue;
              const childRole = roleOf(child) ?? "generic";
              if ((childRole === role || (role === "generic" && !childRole)) && nameOf(child, childRole) === name) found.push(child);
              if (found.length > 1) return;
              visit(child);
            }
          };
          visit(document.documentElement);
          if (found.length === 1) { numOf.set(found[0], n); byNum.set(n, { ref: new WeakRef(found[0]), key: entry.key }); return found[0]; }
        }
        throw new Error("GONE");
      };
    """#
}
#endif
