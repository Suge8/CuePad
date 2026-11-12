# landing/ — 落地页

现在只是一页占位，等大更新后重做。Vercel 项目 `cuepad-landing` 已与 GitHub 断开，推送不部署：上线要从含 `landing/` 的上一层部署（项目的 Root Directory 设的是 `landing`，在本目录里跑会报目录不存在）：`git archive HEAD landing | tar -x -C <临时目录>`，在临时目录里带 `VERCEL_ORG_ID`、`VERCEL_PROJECT_ID`（值在 `.vercel/project.json`）跑 `vercel --prod`；要恢复推送即部署就 `vercel git connect`。

- runtime 在 `svelte.config.js` 固定为 nodejs22.x：不固定时 adapter 按本地 Node（≥26）选，Vercel 不认。
- 颜色只用 `src/styles/base.css` 的令牌，与 App 的 `Palette` 同名同值（`lint.sh` 查）。
- `static/assets/mark.svg` 由 `design/tools/cue-symbols.py` 生成，不手改。
