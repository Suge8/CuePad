# landing/ — 落地页（SvelteKit + Vercel）

双语（EN/中）营销落地页，Svelte 5 + SvelteKit 2 + GSAP，全量预渲染。Vercel 项目 `cuepad-landing` 连着 GitHub `main` 自动部署：推到 main 就上线 [cue-pad.com](https://cue-pad.com)。

```bash
bun install
bun run dev       # http://localhost:8931/
bun run build     # runtime 在 svelte.config.js 固定为 nodejs22.x：不固定时 adapter 按本地 Node（≥26）选，Vercel 不认
```

- 截图用 `design/readme/` 里演示库拍的真实界面图（与 README 同一套）。
- 重生成 `static/art/` 的插画时，prompt 要精确描述吉祥物：白色圆角方形纸片、右上折角、黑椭圆眼、腰间黑色圆环，3D clay 风格，底色 #f4f1ea；描述少一项，生成出来就不像同一个角色。
- GSAP 全部在 `onMount` + `gsap.context(scope)` 内创建，卸载时 `ctx.revert()`：不 revert 的话 ScrollTrigger 的 pin 与滚动监听会留在页面上。移动端（<48rem）与 reduced-motion 跳过 pin、飞行与粒子。
- 文案只改 `DICT`（双语同改）；产品事实以根 [README.md](../README.md) 为准。
