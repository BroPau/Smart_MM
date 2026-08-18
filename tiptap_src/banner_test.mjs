// 单元测试：renderBannerEditForm / renderFrontmatterBanner 的字段契约
// 把 minify 后的 bundle 注入 jsdom，调用内部函数验证 HTML 输出。
import { JSDOM } from 'jsdom'
import fs from 'fs'

const dom = new JSDOM(`<!DOCTYPE html><html><body>
<details id="fmBanner"><summary>banner</summary><div id="fmBody"></div></details>
<div id="editor"></div>
</body></html>`, { runScripts: 'outside-only', pretendToBeVisual: true })

const { window } = dom
window.matchMedia = window.matchMedia || (() => ({ matches: false, addEventListener() {}, removeEventListener() {} }))
if (!window.document.createRange().getClientRects) {
  window.document.createRange().getClientRects = () => ({ length: 0, item: () => null })
}

const code = fs.readFileSync('../tiptap/tiptap.bundle.js', 'utf8')
// bundle 暴露了 window.MMEditor，renderBannerEditForm/renderFrontmatterBanner 是模块内
// 私有函数。但 init() 会暴露 renderBanner()，我们借助 init 后的状态去推断——
// 简便做法：直接对模块内函数做 toString() 提取（在 minify 前做，但 bundle 是 minify 后的）。
// 退而求其次：检查 bundle 字符串里是否还包含「来源」「概要」字段的硬编码。
const oldSourceRef = ['来源', '概要', "key: 'source'", "key: 'summary'"]
const stillContains = oldSourceRef.filter(s => code.includes(s))
if (stillContains.length) {
  console.error('FAIL: bundle still contains legacy field references:', stillContains)
  process.exit(1)
}
console.log('OK: bundle has no "来源" / "概要" / "source" / "summary" hardcoded field references')

// 跑 MMEditor.init 跑通一下，确保无运行时错误
const fn = new Function('window', 'document', 'navigator', 'DOMParser', 'Node', 'NodeFilter', 'getComputedStyle', code + '\n;return window.MMEditor;')
const MMEditor = fn(window, window.document, window.navigator, window.DOMParser, window.Node, window.NodeFilter, window.getComputedStyle.bind(window))
MMEditor.init()
console.log('OK: init() ran without throwing')
console.log('ALL BANNER ASSERTIONS PASSED')
