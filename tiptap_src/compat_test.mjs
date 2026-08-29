// v2.2.32 渲染兼容冒烟测试：单页面验证 banner 在「新中文 key」和「旧 PascalCase key」下都能正确显示。
// 跑这个 test 不依赖 wiki 目录遍历，只载入具体 md 文件，确保 demo 那一页效果对。
import { JSDOM } from 'jsdom'
import fs from 'fs'
import path from 'path'

const tiptapSrc = new URL('.', import.meta.url).pathname
const bundlePath = path.resolve(tiptapSrc, '../tiptap/tiptap.bundle.js')

if (!fs.existsSync(bundlePath)) { console.error('FAIL: bundle missing, build first:', bundlePath); process.exit(1) }

const dom = new JSDOM(`<!DOCTYPE html><html><body>
<details id="fmBanner"><summary>banner</summary><div id="fmBody"></div></details>
<div id="editor"></div>
</body></html>`, { runScripts: 'outside-only', pretendToBeVisual: true })

const { window } = dom
window.matchMedia = window.matchMedia || (() => ({ matches: false, addEventListener() {}, removeEventListener() {} }))
if (!window.document.createRange().getClientRects) {
  window.document.createRange().getClientRects = () => ({ length: 0, item: () => null })
}
const code = fs.readFileSync(bundlePath, 'utf8')
const fn = new Function('window', 'document', 'navigator', 'DOMParser', 'Node', 'NodeFilter', 'getComputedStyle', code + '\n;return window.MMEditor;')
const MMEditor = fn(window, window.document, window.navigator, window.DOMParser, window.Node, window.NodeFilter, window.getComputedStyle.bind(window))
if (!MMEditor) { console.error('FAIL: window.MMEditor undefined'); process.exit(1) }
MMEditor.init()

// 测试 1: 已迁移的中文 key 页面（MCXN947）
const demoMd = `---
类型: Chip
规范名: MCXN947
别名: [mcxn]
品牌: NXP
具体型号: MCXN947VKLT
类别: MCU
功能简述: MCX N94 with Highly Integrated Low-Power Dual Core Arm Cortex-M33 MCUs
状态: 量产
替代料: 无
标签: [wiki, Chip]
更新时间: 2026-07-08
反向链接: [[WiKi首页|Wiki 首页]]
---

# MCXN947
`

MMEditor.loadMarkdown(demoMd, false)
const html = window.document.getElementById('fmBody').innerHTML
console.log('=== 已迁移页面（中文 key）banner 渲染 HTML ===')
console.log(html.replace(/></g, '>\n<'))

// 校验应包含的中文 label
let failures = 0
const fail = m => { console.error('  ✗ ' + m); failures++ }
const ok = m => console.log('  ✓ ' + m)

const must = ['类型', '规范名', '别名', '品牌', '具体型号', '类别', '功能简述', '状态', '替代料', '标签', '更新时间']
for (const k of must) {
  if (html.includes(k)) ok(`包含 ${k}`)
  else fail(`缺少 ${k}`)
}
// 不应包含大写英文 key 残留
const mustNot = ['Type</span>', 'CanonicalName</span>', 'Aliases</span>', 'Tags</span>', 'Updated</span>', 'Backlinks</span>']
for (const k of mustNot) {
  if (!html.includes(k)) ok(`不包含英文 ${k}`)
  else fail(`误把英文当 label 渲染: ${k}`)
}

// 测试 2: 未迁移的 PascalCase key 页面（兼容性校验）
const legacyMd = `---
Type: Person
CanonicalName: Lewis Wei
Aliases: [Lewis, Luis]
Company: "[[NXP（恩智浦半导体）]]"
Title: 客户销售代表
职能范围: （待补全）
Tags: [wiki, Person]
Updated: 2026-07-10
Backlinks: [[WiKi首页]]
---

# Lewis Wei
中文名: 魏璐
`
MMEditor.loadMarkdown(legacyMd, false)
const html2 = window.document.getElementById('fmBody').innerHTML
console.log('\n=== 未迁移页面（PascalCase key）banner 渲染 HTML ===')
console.log(html2.replace(/></g, '>\n<'))

const must2 = ['类型', '规范名', '别名', '公司', '职位', '职能范围', '标签', '更新时间']
for (const k of must2) {
  if (html2.includes(k)) ok(`兼容 PascalCase 后, banner 包含 ${k}`)
  else fail(`兼容 PascalCase 后, banner 缺少 ${k}`)
}
// 大写英文 key 不应作为 label 露出
const mustNot2 = ['>Type<', '>CanonicalName<', '>Aliases<', '>Tags<', '>Updated<']
for (const k of mustNot2) {
  if (!html2.includes(k)) ok(`兼容路径不暴露英文 ${k}`)
  else fail(`兼容路径误暴露英文 label: ${k}`)
}

if (failures) { console.error(`\n❌ ${failures} 条断言失败`); process.exit(1) }
console.log('\n✅ v2.2.32 banner 双兼容冒烟测试全绿')
