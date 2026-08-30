# Meetinsight 操作与维护 SOP

> 最后更新：**2026-08-30** ｜ 版本：**v2.2.75** ｜ 编辑器引擎：**Milkdown（默认）**

本文件为同轮功能变更后的「操作 + 维护」手册。代码变更与本文档须在**同一轮**内同步落地（文档铁律）。

---

## 1. 架构与编辑器引擎
- 默认引擎 **Milkdown**（ProseMirror + commonmark + gfm + 内置 prosemirror-tables）。
- 回退引擎 TipTap / Vditor（终端切换：`defaults write com.weilu.meetingminutes editorEngine tiptap|vditor`）。
- 源码链：`milkdown_src/entry.js` → esbuild → `milkdown/milkdown.bundle.js` → 「Copy Milkdown」Run Script 拷入 `Resources/milkdown/`。
- prosemirror-tables 命令已内置 bundle（`isInTable/findTable/addRow*/deleteRow/addColumn*/deleteColumn/toggleHeaderRow/deleteTable` 等），此前「表格无法编辑」根因是**有命令、无 UI 入口**，v2.2.75 用 `tableToolbarPlugin` 浮动条补齐。

## 2. 双链系统（v2.2.75）
- **frontmatter 双链 = 锚点引用**：`company` / `alternative` / `suspected_alias_of` 等字段的 `[[页面]]` 渲染为可点击链接，点击跳转到目标页**对应区块**（非整页展开）。支持 `[[页面#区块|别名]]`。
  - 磁盘仍存 Obsidian 原生 `[[页面#区块|别名]]`；显示层编码为 `[别名](wikilink:ENC)`，缺失判定只看 base page（忽略锚点）。
- **正文双链**：`[[页面]]` / `[[页面#区块]]` 由 `wikiLinkPlugin` 装饰，点击经 `resolveOrPromptWikiPage → scrollToAnchor` 落地锚点。
- **自动补全**：输入 `[[` 弹出页名；输入 `[[页面#` 跨页拉取目标页标题（`pageHeadings` 消息 + `PAGE_HEADINGS` 缓存），补全为 `[[页面#区块]]`。
- **纪要与 Wiki 同一数据库**：两侧 `markdownEditorRequestsPageList` 都必须返回真实页名（纪要名 + Wiki 页名并集）。返回 `[]` 会被 JS `DOMContentLoaded → getPages` 回环清空 `WIKIPAGES`，双链全判缺失（v2.2.75 已修 `MinutesViewController`）。
- **反向链接**：
  - Wiki 页「🔗引用本页的页面」用正则扫所有 Wiki 页正文（v2.2.75 新增扫 `003_Meeting_Minutes`，列出链接它的纪要，type=「会议纪要」）。
  - 锚点比对时先剥 `#区块` 再小写去空白（`linkTargetKey`）。

## 3. 表格编辑（v2.2.75 `tableToolbarPlugin`）
- 光标进入任意 `<table>` 浮现浮动条（`.pm-table-bar`），按钮：＋行↑ / ＋行↓ / －行 / ＋列← / ＋列→ / －列 / 表头 / 删表。
- Tab / Shift-Tab 跨格移动。
- **引用表（REFS 区间，`<!--REFS_TABLE_BEGIN/END-->`）为自动生成**：浮动条显示「引用表（自动生成，改动不保存）」，在其中手改不落盘（保存时正则剔除、下次重算）。

## 4. 部署流程（单副本，无 .dmg）
1. 编译（传 `-derivedDataPath` → 真构建落在**第 5 层**）：
   ```
   cd Meetinsight/Meetinsight
   xcodebuild -scheme Meetinsight -configuration Debug \
     -derivedDataPath ~/Library/Developer/Xcode/DerivedData
   ```
   → 真构建：`~/Library/Developer/Xcode/DerivedData/Build/Products/Debug/Meetinsight.app`
   （`Meetinsight-<hash>` 第 6 层是陈旧副本，**不要取**。）
2. **部署前断言**（rsync 前必做）：
   - `stat` 各候选 app 内 `milkdown.bundle.js` mtime，取最新者。
   - 校验 bundle 含 `FM_TABLE_BEGIN`（×4）+ `REFS_TABLE_BEGIN`（×6）（只查文件存在不够，旧 bundle 会静默通过）。
   - 空 SRC 会让 `rsync -a "/"` 污染目的目录（已踩坑），务必确认 SRC 非空。
3. 部署（单副本）：
   ```
   rsync -a "$SRC/" ~/Applications/Meetinsight.app/
   codesign --force --deep --sign - ~/Applications/Meetinsight.app
   ```
4. 沙箱无权限杀进程 → 让用户自己 **Quit 再重启 App** 验证。

## 5. 铁律
- **文档同步**：任何功能变更同轮更新 `SOP.md` + `README.md`（顶部「最后更新」+版本+章节）。
- **GitHub 备份**：`git add -A` → commit → `git push origin main`，仓库 `git@github.com:BroPau/Smart_MM.git`，git root = `Meetinsight/Meetinsight/`（SOP/README/PythonEngine 不入库）。
- **Swift 多行字符串字面量**：`MarkdownEditorView.swift` 模板缩进须 ≥ 结束定界符列（light 6 / dark 8 空格），改写脚本只能逐字拷贝、绝不重排缩进。

## 6. 目录与数据契约
- `001_Audio / 002_Transcript / 003_Meeting_Minutes / 004_Desensitize_Cache / 005_LLMWiKi / 006_Runtime_Log`（废弃名 `001_Raw_Inputs` 绝不引入）。
- Wiki 6 类：Person / Company / Chip / Project / Topic / Method（前 3 有专属字段）。
- frontmatter 键名磁盘统一纯英文 PascalCase，读取容错中文键。
