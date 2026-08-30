// Validates the Milkdown engine prototype in jsdom (mirrors tiptap smoke.mjs pattern).
import { JSDOM } from 'jsdom'
import fs from 'fs'

const dom = new JSDOM(`<!DOCTYPE html><html><body>
<div id="editor"></div>
</body></html>`, { pretendToBeVisual: true, url: 'http://localhost/' })

const { window } = dom
global.window = window
global.document = window.document
global.DOMParser = window.DOMParser
global.Node = window.Node
global.NodeFilter = window.NodeFilter
global.getComputedStyle = window.getComputedStyle.bind(window)
global.requestAnimationFrame = (cb) => setTimeout(cb, 0)
global.cancelAnimationFrame = (id) => clearTimeout(id)
global.addEventListener = window.addEventListener.bind(window)
global.removeEventListener = window.removeEventListener.bind(window)
global.dispatchEvent = window.dispatchEvent.bind(window)
global.Event = window.Event
global.CustomEvent = window.CustomEvent
window.matchMedia = window.matchMedia || (() => ({ matches: false, addEventListener() {}, removeEventListener() {} }))
if (!window.document.createRange().getClientRects) {
  window.document.createRange().getClientRects = () => ({ length: 0, item: () => null })
}
// ProseMirror needs these in jsdom:
window.HTMLElement.prototype.scrollIntoView = window.HTMLElement.prototype.scrollIntoView || function () {}

// bridge capture
const messages = []
window.webkit = { messageHandlers: { editorBridge: { postMessage: (m) => messages.push(m) } } }

const protoPath = new URL('./engine_proto.mjs', import.meta.url)
const mod = await import(protoPath)

await mod.init()
console.log('OK: init() ran, editor created')

// Test 1: round-trip with wikilink + frontmatter
const md = `---
type: company
canonical_name: 格力电器
---
# 格力电器

这是正文，引用 [[美的集团]] 与 [[珠海格力|格力]]。

- 项目 A
- [ ] 待办任务
- [x] 已完成任务
`
window.MMEditor.setWikiPages(['格力电器', '美的集团'])
window.MMEditor.loadMarkdown(md, true, 'ir', false, '格力电器')
// loadMarkdown -> buildEditor/create is async; give microtasks time
await new Promise(r => setTimeout(r, 300))
window.MMEditor.requestSave()
await new Promise(r => setTimeout(r, 100))
const saveMsg = messages.find(m => m.type === 'save')
if (!saveMsg) { console.error('FAIL: no save message'); console.log('messages:', messages); process.exit(1) }
console.log('--- serialized markdown ---')
console.log(saveMsg.markdown)
console.log('---------------------------')
const okFront = saveMsg.markdown.startsWith('---') && saveMsg.markdown.includes('type: company')
const okWiki = saveMsg.markdown.includes('[[美的集团]]') && saveMsg.markdown.includes('[[珠海格力|格力]]')
const okBody = saveMsg.markdown.includes('# 格力电器') && saveMsg.markdown.includes('- 项目 A') && saveMsg.markdown.includes('- [ ] 待办任务') && saveMsg.markdown.includes('- [x] 已完成任务')
console.log('frontmatter preserved:', okFront)
console.log('wikilinks round-tripped:', okWiki)
console.log('body preserved:', okBody)
if (okFront && okWiki && okBody) console.log('PASS: core round-trip works')
else { console.error('FAIL: round-trip mismatch'); process.exit(1) }
