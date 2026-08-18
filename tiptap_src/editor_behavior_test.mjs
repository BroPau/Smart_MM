// 行为级验证（jsdom 无头）：直接驱动 ProseMirror 的 handleTextInput / handleKeyDown prop，
// 覆盖两个本次新增交互：① 键入 [[Name]] 自动渲染为 wikilink；② 嵌套列表项开头 Backspace 直接 dedent。
import { JSDOM } from 'jsdom'
import fs from 'fs'
import path from 'path'

const tiptapSrc = new URL('.', import.meta.url).pathname
const bundlePath = path.resolve(tiptapSrc, '../tiptap/tiptap.bundle.js')
if (!fs.existsSync(bundlePath)) { console.error('FAIL: bundle missing, build first'); process.exit(1) }

const dom = new JSDOM(`<!DOCTYPE html><html><body>
<details id="fmBanner"><summary>banner</summary><div id="fmBody"></div></details>
<div id="editor"></div>
</body></html>`, { runScripts: 'outside-only', pretendToBeVisual: true })
const { window } = dom
// TipTap 的 focus()/scrollIntoView 等会用到 requestAnimationFrame；Node 全局没有，补一个 no-op 实现
globalThis.requestAnimationFrame = globalThis.requestAnimationFrame || (cb => { return 0 })
globalThis.cancelAnimationFrame = globalThis.cancelAnimationFrame || (() => {})
window.matchMedia = window.matchMedia || (() => ({ matches: false, addEventListener() {}, removeEventListener() {} }))
if (!window.document.createRange().getClientRects) {
  window.document.createRange().getClientRects = () => ({ length: 0, item: () => null })
}

const code = fs.readFileSync(bundlePath, 'utf8')
// 通过闭包捕获模块内的 editor 实例（不改动生产代码）
const fn = new Function('window', 'document', 'navigator', 'DOMParser', 'Node', 'NodeFilter', 'getComputedStyle',
  code + '\n; return window.MMEditor;')
const MMEditor = fn(window, window.document, window.navigator, window.DOMParser, window.Node, window.NodeFilter, window.getComputedStyle.bind(window))
MMEditor.init()
const ed = MMEditor.getEditor()
const view = ed.view

let failures = 0
const fail = m => { console.error('  ✗ ' + m); failures++ }
const ok = m => console.log('  ✓ ' + m)

// —— 模拟键入：先走 handleKeyDown（真实输入时 keydown 先于 textInput，autoPair 的跳过在 keydown 消费按键），
//    未被 keydown 消费再走 handleTextInput，仍未被处理则手动插入文本 ——
function type(text) {
  let handled = false
  view.someProp('handleKeyDown', h => { const r = h(view, { key: text }); if (r) handled = true; return r })
  if (handled) return
  const sel = view.state.selection
  const from = sel.from, to = sel.to
  handled = false
  view.someProp('handleTextInput', h => { const r = h(view, from, to, text); if (r) handled = true; return r })
  if (!handled) view.dispatch(view.state.tr.insertText(text, from, to))
}
// —— 模拟按键 ——
function key(k) {
  const sel = view.state.selection
  let handled = false
  view.someProp('handleKeyDown', h => { const r = h(view, { key: k }); if (r) handled = true; return r })
  return handled
}
function findWikilinks() {
  const out = []
  view.state.doc.descendants((node, pos) => {
    if (!node.isText) return
    node.marks.forEach(m => { if (m.type.name === 'wikilink' && m.attrs.page) out.push({ text: node.text, page: m.attrs.page, alias: m.attrs.alias, anchor: m.attrs.anchor }) })
  })
  return out
}

// ===== 1) 基础：[[Name]] 自动渲染 =====
ed.commands.setContent('')
ed.commands.focus()
type('[['); type('My'); type('Page'); type(']'); type(']')
{
  const links = findWikilinks()
  if (links.length === 1 && links[0].page === 'MyPage' && links[0].text === 'MyPage') ok('[[MyPage]] 自动渲染为单一 wikilink（page=MyPage）')
  else fail('[[MyPage]] 未正确渲染: ' + JSON.stringify(links))
}

// ===== 2) 别名：[[Name|alias]] 自动渲染（显示 alias，链接 Name）=====
ed.commands.setContent('')
ed.commands.focus()
type('[['); type('My'); type('Page'); type('|'); type('老张'); type(']'); type(']')
{
  const links = findWikilinks()
  if (links.length === 1 && links[0].page === 'MyPage' && links[0].text === '老张' && links[0].alias === '老张') ok('[[MyPage|老张]] 渲染为显示「老张」、链接 MyPage')
  else fail('[[MyPage|老张]] 未正确渲染: ' + JSON.stringify(links))
}

// ===== 3) 锚点：[[Name#anchor]] 自动渲染 =====
ed.commands.setContent('')
ed.commands.focus()
type('[['); type('My'); type('Page'); type('#'); type('章节一'); type(']'); type(']')
{
  const links = findWikilinks()
  if (links.length === 1 && links[0].page === 'MyPage' && links[0].anchor === '章节一') ok('[[MyPage#章节一]] 渲染（page=MyPage, anchor=章节一）')
  else fail('[[MyPage#章节一]] 未正确渲染: ' + JSON.stringify(links))
}

// ===== 4) 普通 ] 不受影响（markdown 链接 [text](url) 的 ] 仍正常插入）=====
ed.commands.setContent('')
ed.commands.focus()
type('['); type('text'); type(']'); type('('); type('http://x'); type(')')
{
  const txt = view.state.doc.textContent
  if (txt === '[text](http://x)') ok('普通 [text](url) 的 ] 正常插入，不被吞')
  else fail('普通 ] 异常: ' + JSON.stringify(txt))
}

// ===== 5) Backspace 在嵌套列表项开头直接 dedent =====
// 构造：顶层项 A；父项 B 内含嵌套项 C。光标置于 C 开头，Backspace 应把 C 提升到与 B 同级。
ed.commands.setContent('<ul><li>A</li><li>B<ul><li>C</li></ul></li></ul>')
// 找到文本 "C" 所在的文本块起始位置
let cPos = null
view.state.doc.descendants((node, pos) => { if (node.isText && node.text === 'C') cPos = pos })
if (cPos == null) { fail('未能定位嵌套项 C'); }
else {
  ed.commands.setTextSelection(cPos)
  const beforeDepth = (() => { const $ = view.state.doc.resolve(cPos); let d = $.depth, nested = false; for (; d >= 1; d--) { const n = $.node(d); if (n.type.name === 'listItem' || n.type.name === 'taskItem') { const gp = d - 2 >= 0 ? $.node(d - 2) : null; if (gp && (gp.type.name === 'listItem' || gp.type.name === 'taskItem')) nested = true; break } } return nested })()
  const handled = key('Backspace')
  // 提升后：C 应不再嵌套在列表项内（即 C 的 listItem 的父不再是某个 listItem 的子列表）
  const afterNested = (() => { const $ = view.state.doc.resolve(cPos); let d = $.depth, nested = false; for (; d >= 1; d--) { const n = $.node(d); if (n.type.name === 'listItem' || n.type.name === 'taskItem') { const gp = d - 2 >= 0 ? $.node(d - 2) : null; if (gp && (gp.type.name === 'listItem' || gp.type.name === 'taskItem')) nested = true; break } } return nested })()
  if (beforeDepth && handled && !afterNested) ok('嵌套列表项开头 Backspace 直接 dedent（C 提升为顶层项）')
  else fail(`Backspace dedent 异常: beforeNested=${beforeDepth} handled=${handled} afterNested=${afterNested}`)
}

// ===== 6) 顶层列表项开头 Backspace：ListBackspace 扩展本身应返回 false（不拦截，交默认合并）=====
// 说明：TipTap 把全部 addKeyboardShortcuts 编译进同一个 keymap 插件，someProp('handleKeyDown') 合并后会
//       返回 true（来自 StarterKit 默认 listKeymap 的 lift/merge），这属于正常默认行为，并非本扩展误拦截。
//       因此此处直接调用「本扩展的 handler」校验其契约：顶层项必须返回 false，不执行 dedent。
ed.commands.setContent('<ul><li>top</li></ul>')
let tPos = null
view.state.doc.descendants((node, pos) => { if (node.isText && node.text === 'top') tPos = pos })
ed.commands.setTextSelection(tPos)
const lbExt = ed.extensionManager.extensions.find(e => e.name === 'listBackspace')
const lbHandler = lbExt.config.addKeyboardShortcuts.call(lbExt, { editor: ed })
const r2 = lbHandler.Backspace({ editor: ed, view: ed.view, event: { key: 'Backspace' } })
if (r2 === false) ok('顶层列表项 Backspace：ListBackspace 扩展返回 false（不拦截，交默认合并行为）')
else fail('顶层列表项 Backspace：ListBackspace 扩展应返回 false，但返回 ' + r2 + '（会误 dedent）')

if (failures) { console.error(`\n❌ ${failures} 条行为断言失败`); process.exit(1) }
console.log('\n✅ 全部交互行为断言通过（[[ ]] 自动渲染 + 列表 Backspace 缩进）')
