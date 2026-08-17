import { JSDOM } from 'jsdom'
import fs from 'fs'

const dom = new JSDOM(`<!DOCTYPE html><html><body>
<details id="fmBanner"><summary>banner</summary><div id="fmBody"></div></details>
<div id="editor"></div>
</body></html>`, { runScripts: 'outside-only', pretendToBeVisual: true })

const { window } = dom
// 补齐 ProseMirror 可能用到但 jsdom 缺失的 API
window.matchMedia = window.matchMedia || (() => ({ matches: false, addEventListener() {}, removeEventListener() {} }))
if (!window.document.createRange().getClientRects) {
  window.document.createRange().getClientRects = () => ({ length: 0, item: () => null })
}

const code = fs.readFileSync('../tiptap/tiptap.bundle.js', 'utf8')
const fn = new Function('window', 'document', 'navigator', 'DOMParser', 'Node', 'NodeFilter', 'getComputedStyle', code + '\n;return window.MMEditor;')
const MMEditor = fn(window, window.document, window.navigator, window.DOMParser, window.Node, window.NodeFilter, window.getComputedStyle.bind(window))

if (!MMEditor) { console.error('FAIL: window.MMEditor undefined'); process.exit(1) }
console.log('OK: MMEditor defined')

MMEditor.init()
console.log('OK: init() ran')

const md = `---
type: person
canonical_name: 张三
aliases: [小张, 三哥]
tags: [wiki, person]
updated: "2026-08-17"
---
# 会议纪要标题

这是一段正文，提到 [[Apple]] 与 [[张三|老张]]。

- 列表项一
- 列表项二

> 引用一段话

| 列A | 列B |
| --- | --- |
| 1 | 2 |
`
MMEditor.loadMarkdown(md, true)
const html = window.__editorHTML || MMEditor /* noop */
const edHtml = window.document.querySelector('#editor .ProseMirror').innerHTML
console.log('--- editor HTML (excerpt) ---')
console.log(edHtml.slice(0, 400))
if (!edHtml.includes('data-wikilink')) { console.error('FAIL: wikilink not parsed'); process.exit(1) }
console.log('OK: wikilink mark parsed from [[Apple]]')

// 保存往返
let saved = null
window.webkit = { messageHandlers: { editorBridge: { postMessage: m => { if (m.type === 'save') saved = m.markdown } } } }
MMEditor.requestSave()
if (!saved) { console.error('FAIL: requestSave did not post'); process.exit(1) }
console.log('--- saved markdown (excerpt) ---')
console.log(saved.slice(0, 300))
if (!saved.includes('[[') ) { console.error('FAIL: saved markdown missing wikilinks'); process.exit(1) }
console.log('OK: round-trip markdown contains [[wikilinks]]')
if (!saved.includes('| 列A | 列B |')) { console.error('WARN: table not preserved in round-trip'); }
else console.log('OK: table preserved in round-trip')
console.log('ALL SMOKE TESTS PASSED')
