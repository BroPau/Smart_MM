// Loads the REAL esbuild bundle (milkdown.bundle.js) in jsdom and verifies round-trip.
import { JSDOM } from 'jsdom'
import fs from 'fs'
import { fileURLToPath } from 'url'

const __dirname = new URL('.', import.meta.url)
const bundlePath = new URL('../milkdown/milkdown.bundle.js', __dirname)
const code = fs.readFileSync(bundlePath, 'utf8')

const html = `<!DOCTYPE html><html><body>
<details id="fmBanner"><summary>属性</summary><div id="fmBody"></div></details>
<div id="editor"></div>
<div id="fmPageRefsContainer"></div>
<div id="wikiPreview" class="wiki-preview" style="display:none"></div>
</body></html>`

const dom = new JSDOM(html, { pretendToBeVisual: true, url: 'http://localhost/', runScripts: 'dangerously' })
const { window } = dom
const document = window.document

// polyfills for ProseMirror / Milkdown
window.matchMedia = window.matchMedia || (() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }))
window.HTMLElement.prototype.scrollIntoView = window.HTMLElement.prototype.scrollIntoView || function () {}
if (!window.document.createRange().getClientRects) {
  window.document.createRange().getClientRects = () => ({ length: 0, item: () => null })
}
const cr = window.document.createRange()
if (!cr.getClientRects) cr.getClientRects = () => ({ length: 0, item: () => null })

// bridge capture
const messages = []
window.webkit = { messageHandlers: { editorBridge: { postMessage: (m) => messages.push(m) } } }

// run the bundle in the window's global scope
window.eval(code)

// trigger the DOMContentLoaded path (init + window globals + getPages)
window.document.dispatchEvent(new window.Event('DOMContentLoaded'))

const sleep = (ms) => new Promise(r => setTimeout(r, ms))

await sleep(500)
if (!window.MMEditor) { console.error('FAIL: window.MMEditor not defined after bundle load'); process.exit(1) }
console.log('OK: bundle evaluated, window.MMEditor present')

// Test: frontmatter + wikilinks + task list round-trip
const md = `---
type: company
canonical_name: 格力电器
tags: [wiki, Company]
---
# 格力电器

这是正文，引用 [[美的集团]] 与 [[珠海格力|格力]]。

- 项目 A
- [ ] 待办任务
- [x] 已完成任务
`
window.MMEditor.setWikiPages(['格力电器', '美的集团'])
window.MMEditor.loadMarkdown(md, true, 'ir', false, '格力电器')
await sleep(400)
window.MMEditor.requestSave()
await sleep(200)
const saveMsg = messages.find(m => m.type === 'save')
if (!saveMsg) { console.error('FAIL: no save message'); console.log('messages:', JSON.stringify(messages)); process.exit(1) }
console.log('--- serialized markdown ---')
console.log(saveMsg.markdown)
console.log('---------------------------')
const okFront = saveMsg.markdown.startsWith('---') && saveMsg.markdown.includes('type: company') && saveMsg.markdown.includes('canonical_name: 格力电器')
const okWiki = saveMsg.markdown.includes('[[美的集团]]') && saveMsg.markdown.includes('[[珠海格力|格力]]')
const okBody = saveMsg.markdown.includes('# 格力电器') && saveMsg.markdown.includes('- 项目 A') && saveMsg.markdown.includes('- [ ] 待办任务') && saveMsg.markdown.includes('- [x] 已完成任务')
const okBullet = !saveMsg.markdown.includes('* 项目 A') && !saveMsg.markdown.includes('* [ ] 待办任务')
console.log('frontmatter preserved:', okFront)
console.log('wikilinks round-tripped:', okWiki)
console.log('body preserved:', okBody)
console.log('bullet style kept as "-":', okBullet)

const okHeading = messages.some(m => m.type === 'getPages') || messages.some(m => m.type === 'getCustomTypes')
console.log('bridge handshake messages present (getPages/getCustomTypes):', okHeading)

if (okFront && okWiki && okBody && okBullet && okHeading) console.log('PASS: real-bundle round-trip works')
else { console.error('FAIL: round-trip mismatch'); process.exit(1) }
