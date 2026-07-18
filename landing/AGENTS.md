# landing/ — 产品落地页（SvelteKit + Vercel）

CuePad 双语（EN/中）营销落地页：**Svelte 5（runes）+ SvelteKit 2 + GSAP**，`@sveltejs/adapter-vercel` 全量预渲染。公开址 [cue-pad.com](https://cue-pad.com)；Vercel 项目 `cuepad-landing` 的 Root Directory 为本目录，已连 GitHub `main` 自动部署。

## 命令

```bash
bun install
bun run dev       # http://localhost:8931/
bun run build     # vite build + adapter-vercel（本地 Node≥26 时 runtime 已在 svelte.config.js 固定为 nodejs22.x）
```

## 结构

| 路径 | 职责 |
| --- | --- |
| `src/app.html` | meta/OG/字体 preload + **首绘前语言引导脚本**（localStorage → `data-lang`） |
| `src/app.css` | 「纸面工作室」设计系统：OKLCH token 由应用品牌色 1:1 换算，Bricolage Grotesque 自托管 + 系统 CJK，含 hero 入场 CSS 编排与 reduced-motion 全量兜底 |
| `src/lib/i18n.svelte.ts` | 文案单一事实源 `DICT` + `i18n.lang`（$state）+ `t()`；**boot 语言在水合后经 `applyBootLang()` 应用**——预渲染是 en，若在水合前改状态，`{@html}` 块会保留 SSR 旧文案 |
| `src/lib/gsap.ts` | GSAP 单点注册（ScrollTrigger / MotionPath / DrawSVG / SplitText，3.13+ 全插件免费） |
| `src/lib/icons.ts` + `Icon.svelte` | 内联 Lucide 风格图标集（github/download/star/send/pen-line/command/…） |
| `src/lib/components/` | Nav（进度条+吸顶）、Hero（分栏+生成插画+鼠标视差/磁吸）、Sim（投送模拟，WAAPI）、GhostBand（描边大字滚动带）、**Drench（ScrollTrigger pin：纸飞机沿 MotionPath 飞行 + DrawSVG 金线 + 屏幕点亮 + 星光爆发）**、Steps、Features（clip-path 揭示 + 图内视差）、DeskBand（生成插画视差带）、Cinema、Download（Releases 下载 + 星光爆发）、Footer、Canvas（尘埃/星光粒子场） |
| `static/assets/` | 截图 WebP（源自 `design/promo/shots/raw/` **纯界面图**，禁用带白底的 `final/`）、演示 MP4、Ken Burns 视频、吉祥物、字体、favicon、og.jpg |
| `static/art/` | **gpt-image 生成的品牌插画**（`hero-plane.webp` 骑纸飞机、`desk.webp` 俯视桌面）；重生成时 prompt 必须精确描述吉祥物：白色圆角方形纸片、右上折角、黑椭圆眼、腰间黑色圆环，3D clay 风格，底色 #f4f1ea |

## 约定

- 下载入口一律 `LINKS.download`（`/releases/latest/download/CuePad-mac-arm64.zip` 稳定直链）；旁路 GitHub 星标/源码用 `LINKS.repo`。发版 zip 文件名不得带版本号（见根目录 `electron-builder.yml` `artifactName`）。
- GSAP 全部在 `onMount` + `gsap.context(scope)` 内创建，卸载 `ctx.revert()`；移动端（<48rem）与 reduced-motion 跳过 pin/飞行/粒子。
- Sim 投送芯片动画不要依赖 `fill:'forwards'` 残留——完成后必须 `cancel()`，否则动画样式压过内联样式永久可见。
- 新增文案只改 `DICT`（双语同改）；产品事实以根 [README.md](../README.md) 为准。
