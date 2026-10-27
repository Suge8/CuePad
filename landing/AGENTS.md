# landing/ — 落地页（SvelteKit + Vercel）

双语（EN/中）营销落地页，Svelte 5 + SvelteKit 2 + GSAP，全量预渲染。Vercel 项目 `cuepad-landing` 连着 GitHub `main` 自动部署：推到 main 就上线 [cue-pad.com](https://cue-pad.com)。

```bash
bun install
bun run dev       # http://localhost:8931/
bun run build     # runtime 在 svelte.config.js 固定为 nodejs22.x：不固定时 adapter 按本地 Node（≥26）选，Vercel 不认
```

- 颜色只用 `src/styles/base.css` 的令牌：与 App 的 Palette 同名同值（`apple/scripts/lint.sh` 查），浅深两档写成 `light-dark()`，整段深色只给 `.night`。主按钮是墨，靛青只给焦点与在动的东西；字是系统字栈，不加网络字体。
- 截图都是演示库拍的真实界面：浅色的用 `xc.sh shot mac <图> -- -CuePadDemo YES -CuePadWindowSize 1600x1000 -theme light -CuePadScene <画面>` 拍，深色看板、手机图与 og 图取自 `design/readme/`（与 README 同一套），转成 webp 放 `static/assets/shots/`。
- 重生成吉祥物素材（`static/assets/mascot-*`、`static/assets/loops/`）时，prompt 要精确描述吉祥物：白色圆角方形纸片、右上折角、黑椭圆眼、腰间黑色圆环，3D clay 风格，底色 #f4f1ea；描述少一项，生成出来就不像同一个角色。
- GSAP 全部在 `onMount` + `gsap.context(scope)` 内创建，卸载时 `ctx.revert()`：不 revert 的话 ScrollTrigger 的 pin 与滚动监听会留在页面上。移动端（<48rem）与 reduced-motion 跳过 pin、飞行与粒子。
- 文案只改 `DICT`（双语同改）；产品事实以根 [README.md](../README.md) 为准。
