# Meetinsight（Smart_MM）

> 最后更新：**2026-08-30** ｜ 文档版本：**v2.2.75** ｜ 编辑器引擎：**Milkdown（默认）**

Meetinsight 是一款 macOS（AppKit）原生 Markdown / 笔记应用，主打：
- **Typora 风格实时渲染**：输入即所见，无需切预览。
- **Obsidian 式双链**：正文与 frontmatter 均支持 `[[页面]]` / `[[页面#区块]]`，并自动补全。
- **纪要与 Wiki 同一数据库**：会议纪要（003_Meeting_Minutes）与 LLM Wiki（005_LLMWiKi）双向互通，`[[ ]]` 互链、反向链接互相列出。
- **表格所见即所得**：正文 / 引用表均可用浮动工具条增删行列、切表头、删表。

详细操作与部署规范见同目录 **SOP.md**；本次修复明细见 **BUG_FIX_LOG.md**。

## v2.2.75 关键变更（本轮）
1. **frontmatter 双链改为「锚点引用」**：`company` / `alternative` / `suspected_alias_of` 等字段的 `[[页面]]` 渲染为可点击链接，点击跳转到目标页的**对应区块**（而非整页展开）；支持 `[[页面#区块|别名]]` 形态。
2. **表格工具条（WYSIWYG）**：光标进入任意表格浮现浮动条，支持加行（上/下）、删行、加列（左/右）、删列、切表头、删表；引用表（REFS 区间）为自动生成，工具条显示「引用表（自动生成，改动不保存）」且编辑不落盘。
3. **纪要与 Wiki 双向互通**：
   - 正向：纪要里 `[[Wiki页]]` 现在能识别、自动补全、点击跳转（此前 `markdownEditorRequestsPageList` 返回空，被 JS 回环清空导致全判缺失）。
   - 反向：Wiki 页「🔗引用本页的页面」现在也会列出链接它的会议纪要。
   - 锚点双链 `[[页面#区块]]` 在两侧均生效。

## 常用切换
- 回退引擎：`defaults write com.weilu.meetingminutes editorEngine tiptap | vditor`（默认 milkdown）。
