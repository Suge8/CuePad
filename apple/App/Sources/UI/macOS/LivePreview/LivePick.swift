#if os(macOS)
import AppKit
import SwiftUI

/// 点选页面元素的注入脚本（`LivePreview.pick`）。跑在页面自己的内容世界里：React、Vue、Svelte 开发模式挂在元素上的组件信息只有那里看得到；
/// 页面上只留一个以 Symbol 为键的句柄（收起时拿它取消），点完、取消都拆干净（高亮层、光标样式、监听）。
enum LivePick {
    private static let key = "Symbol.for('cuepad.pick')"
    static let cancel = "window[\(key)]?.cancel()"

    /// 高亮框与标签的颜色（脚本里的 `tint`、`ink`）：此刻外观下实心钮的那一对（`Palette.signatureFill` 底、`onFill` 字），深浅色下标签的字都读得清。
    static var colors: [String: String] {
        let palette = Palette(dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        func css(_ color: Color) -> String {
            let rgb = color.resolve(in: EnvironmentValues())
            return "rgb(\(Int(rgb.red * 255)), \(Int(rgb.green * 255)), \(Int(rgb.blue * 255)))"
        }
        return ["tint": css(palette.signatureFill), "ink": css(palette.onFill)]
    }

    static func element(_ found: [String: Any]) -> ReplyNote.Element? {
        guard let page = found["page"] as? String, let selector = found["selector"] as? String, let tag = found["tag"] as? String else { return nil }
        return ReplyNote.Element(page: page, selector: selector, tag: tag, text: found["text"] as? String ?? "",
                                 component: found["component"] as? String, source: found["source"] as? String)
    }

    static let script = """
        const key = \(key);
        window[key]?.cancel();
        const css = CSS.escape;

        const selector = element => {
            const parts = [];
            for (let node = element; node && node !== document.documentElement; node = node.parentElement) {
                if (node.id) {
                    parts.unshift("#" + css(node.id));
                } else {
                    const classes = [...node.classList].filter(name => !/\\d{3,}|^(is|has)-|hover|active|focus/.test(name)).slice(0, 2);
                    let part = node.tagName.toLowerCase() + classes.map(name => "." + css(name)).join("");
                    const twins = node.parentElement ? [...node.parentElement.children].filter(other => other.tagName === node.tagName) : [];
                    if (twins.length > 1 && document.querySelectorAll(parts.length ? part + " > " + parts.join(" > ") : part).length > 1) {
                        part += `:nth-of-type(${twins.indexOf(node) + 1})`;
                    }
                    parts.unshift(part);
                }
                const candidate = parts.join(" > ");
                if (document.querySelectorAll(candidate).length === 1) return candidate;
            }
            return parts.join(" > ");
        };

        const origin = element => {
            const marked = element.closest("[data-component], [data-source], [data-insp-path], [data-v-inspector]");
            if (marked) {
                const data = marked.dataset;
                return { component: data.component ?? null, source: data.source ?? data.inspPath ?? data.vInspector ?? null };
            }
            for (let node = element; node; node = node.parentElement) {
                const fiberKey = Object.keys(node).find(name => name.startsWith("__reactFiber$"));
                if (fiberKey) {
                    for (let fiber = node[fiberKey]; fiber; fiber = fiber.return) {
                        const type = fiber.type;
                        if (typeof type === "function" || (type && typeof type === "object" && (type.render || type.type))) {
                            const name = type.displayName ?? type.name ?? type.render?.name ?? type.type?.name;
                            const at = fiber._debugSource;
                            if (name) return { component: name, source: at ? `${at.fileName}:${at.lineNumber}` : null };
                        }
                    }
                }
                const vue = node.__vueParentComponent?.type;
                if (vue) return { component: vue.__name ?? vue.name ?? null, source: vue.__file ?? null };
                const svelte = node.__svelte_meta?.loc;
                if (svelte) return { component: null, source: `${svelte.file}:${svelte.line}` };
            }
            return { component: null, source: null };
        };

        const describe = element => {
            const text = (element.innerText || element.value || element.placeholder || element.getAttribute("aria-label") || element.alt || element.title || "")
                .replace(/\\s+/g, " ").trim().slice(0, 120);
            return { page: location.href, selector: selector(element), tag: element.tagName.toLowerCase(), text, ...origin(element) };
        };

        const layer = document.createElement("div");
        layer.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647";
        const box = document.createElement("div");
        const ease = "cubic-bezier(.16,1,.3,1)";
        const glide = ["left", "top", "width", "height", "border-radius"].map(property => `${property} .12s ${ease}`).join(",");
        box.style.cssText = `position:fixed;box-sizing:border-box;border:2px solid ${tint};border-radius:6px;background:color-mix(in srgb, ${tint} 14%, transparent);opacity:0`;
        const label = document.createElement("div");
        label.style.cssText = `position:fixed;padding:2px 8px;border-radius:6px;background:${tint};color:${ink};font:600 12px/18px -apple-system,system-ui,sans-serif;white-space:nowrap;opacity:0`;
        layer.append(box, label);
        document.documentElement.append(layer);
        const cursor = document.createElement("style");
        cursor.textContent = "*, *::before, *::after { cursor: crosshair !important; }";
        document.head.append(cursor);

        const pad = 3, gap = 4, reach = 24;
        let current = null;
        const show = element => {
            current = element;
            if (!element) {
                box.style.opacity = label.style.opacity = 0;
                return;
            }
            // 框比元素大一圈、圆角随元素（圆头像就是圆框）：贴着画的话描边压在字上
            const rect = element.getBoundingClientRect(), radius = getComputedStyle(element).borderTopLeftRadius;
            const round = radius.endsWith("%") ? Math.min(rect.width, rect.height) * parseFloat(radius) / 100 : parseFloat(radius) || 0;
            // 悬停的反馈立刻到位，只在元素之间换的时候滑过去；也不能靠淡入：窗口被挡住时 WebKit 停掉页面动画，淡入会停在透明
            box.style.transition = box.style.opacity === "1" ? glide : "none";
            Object.assign(box.style, {
                left: rect.left - pad + "px", top: rect.top - pad + "px", width: rect.width + 2 * pad + "px", height: rect.height + 2 * pad + "px",
                borderRadius: round + pad + "px", opacity: 1,
            });
            const { component } = origin(element);
            const name = element.tagName.toLowerCase() + (element.id ? "#" + element.id : element.classList[0] ? "." + element.classList[0] : "");
            label.textContent = (component ? component + " › " : "") + name;
            // 标签在框外、不压着元素：元素占的那一截连伸出它的子元素（头像的角标）一起算，只算贴着它的那一圈（滚出去的远处不算，大容器只看前几百个）；
            // 上方放不下就放到下方，下方也出了可视范围就贴着可视范围的下沿
            let top = rect.top - pad, bottom = rect.bottom + pad, seen = 0;
            for (const child of element.querySelectorAll("*")) {
                if (++seen > 400) break;
                const area = child.getBoundingClientRect();
                if (!area.width || !area.height || area.bottom < rect.top - reach || area.top > rect.bottom + reach) continue;
                top = Math.max(rect.top - reach, Math.min(top, area.top));
                bottom = Math.min(rect.bottom + reach, Math.max(bottom, area.bottom));
            }
            const height = label.offsetHeight, above = top - gap - height;
            label.style.top = (above >= gap ? above : Math.min(bottom + gap, innerHeight - height - gap)) + "px";
            label.style.left = Math.max(gap, Math.min(rect.left - pad, innerWidth - label.offsetWidth - gap)) + "px";
            label.style.opacity = 1;
        };

        return await new Promise(resolve => {
            const swallow = event => {
                event.preventDefault();
                event.stopImmediatePropagation();
            };
            const over = event => { if (event.target instanceof Element && event.target !== current) show(event.target); };
            const out = event => { if (!event.relatedTarget) show(null); };
            const click = event => {
                swallow(event);
                finish(current ?? event.target);
            };
            const escape = event => {
                if (event.key !== "Escape") return;
                swallow(event);
                finish(null);
            };
            const follow = () => current && show(current);
            const listeners = [["mouseover", over], ["mouseout", out], ["pointerdown", swallow], ["mousedown", swallow], ["pointerup", swallow],
                               ["mouseup", swallow], ["click", click], ["dblclick", swallow], ["keydown", escape], ["scroll", follow]];
            const finish = element => {
                for (const [type, listener] of listeners) removeEventListener(type, listener, true);
                layer.remove();
                cursor.remove();
                delete window[\(key)];
                resolve(element instanceof Element ? describe(element) : null);
            };
            for (const [type, listener] of listeners) addEventListener(type, listener, true);
            window[\(key)] = {
                cancel: () => finish(null),
                hover: query => show(document.querySelector(query)),
                pick: query => finish(document.querySelector(query)),
            };
        });
        """
}
#endif
