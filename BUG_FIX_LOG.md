# BUG / 功能变更日志（BUG_FIX_LOG）

> 仅记录「根因 → 修复 → 验证」三段式。文档版本随 SOP.md / README.md 同步升版。

---

## v2.2.75（2026-08-30）

### 1. frontmatter 双链引用整页 → 改为引用区块（锚点跳转）
- **背景**：用户希望 frontmatter 里 `company` 等字段的双链只引用目标页的**对应区块**，而非把整页相关内容包括进来。
- **改动**：
  - `entry.js` 新增 `parseWikiTarget(v)` 归一化 `[[页面#区块|别名]]` / `[别名](wikilink:ENC)` / 裸文本三种形态；`itemToWikilink` 生成 Obsidian 原生 `[[页面#区块|别名]]`，显示层编码 `wikilink:ENC`（ENC = `encodeURIComponent(页面#区块)`）。
  - `wikilinkInsideCodePlugin` 正则同时匹配 `[n](wikilink:ENC)` 与 `[[页面#区块]]`，缺失判定只看 base page；加 `data-anchor` + `wikilink-anchored` class。
  - `wikiLinkPlugin` / `applyWikiLink` / `autoRenderWikiLink` href 携带「页面#区块」全量；`showPreviewFor` 优先取 `data-wikilink`。
  - 宿主 `WikiViewController` / `MinutesViewController` 预览按 `MarkdownBlocks.block` 切片返区块（否则返 `summaryBlock` 概要）。
- **验证**：bundle 含 `wikilink-anchored`×2；点击 frontmatter 双链跳转到对应区块。

### 2. 表格无法只编辑 → 新增浮动工具条（WYSIWYG）
- **背景**：用户要求正文（含 refs 引用表）里的双链表格也能增删行列、自动对齐。
- **改动**：
  - `entry.js` import `@milkdown/prose/tables` 命令；新增 `tableToolbarPlugin` + `TableBarView`，光标在表格内浮现工具条（＋行↑/↓、－行、＋列←/→、－列、表头、删表），Tab/Shift-Tab 跨格移动。
  - `derivedTableRanges(doc)` 识别 REFS 区间，引用表工具条禁用并提示「自动生成，改动不保存」。
  - `MarkdownEditorView.swift` 四套模板补 `.pm-table-bar*` / `.wikilink-anchored::after` / `.selectedCell:after` 样式。
- **验证**：bundle 含 `pm-table-bar`×4、`tableToolbarPlugin`×2；光标入表浮现工具条。

### 3. 纪要与 Wiki 双链不互通 → 双向互通
- **根因**：`MinutesViewController.markdownEditorRequestsPageList` 返回 `[]`，被 JS `DOMContentLoaded → getPages` 回环清空 `WIKIPAGES`，纪要里 `[[Wiki页]]` 全判缺失；Wiki 页「引用本页」未扫纪要目录。
- **改动**：
  - `MinutesViewController.markdownEditorRequestsPageList` 返回 `WikiIndex.shared.wikiNames + items.map { $0.name }`；新增 `splitTarget` / `readPageMarkdown` / `openMinute(named:anchor:)` / `markdownEditorHeadings` / `markdownEditorPreviewForWikilink`。
  - `WikiViewController`：`referencesToThis` 末尾 `append(minutesReferencing(targets:))`；`resolveOrPromptWikiPage` 未命中 Wiki 页时回退 `openMinute`；`markdownEditorRequestsPageList` 加 `minuteNames()`。
  - `MainContainerViewController` 新增 `openMinute(_:anchor:)`；`WikiIndex` 加 `url(for:)` / `markdown(forRawName:)`。
  - `MarkdownBlocks` 新增 `headings` / `block` / `summaryBlock` / `stripFrontmatter` / `normalize`。
- **验证**：bundle 含 `setPageHeadings`×3、`pageHeadings`×2；纪要 `[[Wiki页]]` 可补全/跳转，Wiki 反向链接列出纪要。

### 影响文件
- `milkdown_src/entry.js`
- `Meetinsight/MarkdownEditorView.swift`
- `Meetinsight/MinutesViewController.swift`
- `Meetinsight/WikiViewController.swift`
- `Meetinsight/WikiIndex.swift`
- `Meetinsight/MainContainerViewController.swift`
- 部署：`~/Applications/Meetinsight.app`（rsync + ad-hoc codesign）

### 部署断言
- `xcodebuild -derivedDataPath` 真构建在第 5 层 `DerivedData/Build/Products/Debug/Meetinsight.app`（mtime 2026-08-30 18:58:24）。
- bundle 含 `FM_TABLE_BEGIN`×4、`REFS_TABLE_BEGIN`×6、`pm-table-bar`×4，均通过。
