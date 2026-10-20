# design/promo 物料索引

宣传物料的合成模板与成图。新截图来自 `apple/scripts/xc.sh shot`（隔离演示库，见 docs/verify.md），不碰真实用户数据。

产品事实以根 [README.md](../../README.md) 为准；成图上的字在 `compose/` 的模板里，改物料时对齐 README。

| 路径 | 说明 |
| --- | --- |
| `shots/raw/`、`shots/final/` | 旧版界面的窗口截图与加框成图；`compose/` 的 hero / social 模板读的 `raw/board-light-collapsed.png` 还没有，补 Swift 版截图时放这里 |
| `compose/` | HTML 合成模板与 `compose.mjs`（用法在它的头注释）；hero / social 模板加 `?lang=en` 出英文版。仓库不带 package.json，运行前 `npm i --no-save @playwright/test` |
| `visual/` | 成图：README hero、GitHub social preview、抠图素材（`design/tools/cutout.swift` 产物） |
