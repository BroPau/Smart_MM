// 数据驱动校验：把 minify 后的 bundle 注入 jsdom，加载「真实 Wiki 页」，
// 断言顶部属性 banner 显示的内容 = 该页 frontmatter 的「实际键集合」——
// 不漏字段、不猜测/硬编类型专属字段、不含来源/概要（它们只在正文）。
import { JSDOM } from 'jsdom'
import fs from 'fs'
import path from 'path'

const tiptapSrc = new URL('.', import.meta.url).pathname
const bundlePath = path.resolve(tiptapSrc, '../tiptap/tiptap.bundle.js')
const wikiDir = path.resolve(tiptapSrc, '../../PythonEngine/005_LLMWiKi/wiki_pages')

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
console.log('OK: MMEditor.init() ran')

// —— 复制 entry.js 的 frontmatter 解析，得到每页「实际键集合」——
function splitFrontmatter(md) {
  const L = (md || '').replace(/\r\n/g, '\n').split('\n')
  if (L.length && L[0].trim() === '---') {
    let j = 1
    while (j < L.length && L[j].trim() !== '---') j++
    if (j < L.length) return { fmRaw: L.slice(0, j + 1).join('\n'), body: L.slice(j + 1).join('\n') }
  }
  return { fmRaw: '', body: md || '' }
}
function parseFrontmatter(text) {
  const fm = {}
  const lines = text.split('\n')
  let i = 0
  while (i < lines.length) {
    const m = lines[i].match(/^([^\s:]+):\s*(.*)$/)
    if (!m) { i++; continue }
    const key = m[1]; let val = m[2].trim()
    if (val === '') {
      const items = []; let j = i + 1
      while (j < lines.length) { const st = lines[j].match(/^\s+-\s+(.*)$/); if (st) { items.push(st[1].trim()); j++; continue } break }
      if (items.length) fm[key] = items
      i = j
    } else { fm[key] = val; i++ }
  }
  return fm
}
// v2.2.29 起：标签统一中文化（与 entry.js 的 fmLabel / FM_LABEL_CN 完全一致），
// 不再直接显示英文键名。期望值 = 每个键经 fmLabel 翻译后的中文标签。
const SKIP = { wiki_首页: 1 }
const FM_LABEL_CN = {
  type: '类型', canonical_name: '规范名', company: '公司', title: '职位',
  aliases: '别名', tags: '标签', updated: '更新时间', backlinks: '反向链接'
}
const labelOf = k => FM_LABEL_CN[k] || k
// 与 entry.js 的 fmDisplay 保持一致：空值（数组空 / 标量空）在只读 banner 中不渲染行
function dispOf(v) {
  if (v === undefined || v === null) return ''
  let s = Array.isArray(v) ? v.map(x => String(x).trim()).filter(Boolean).join('、') : String(v).trim()
  s = s.replace(/^[\[\(](.*)[\]\)]$/, '$1').replace(/^["“”']|["“”']$/g, '')
  return s
}

let failures = 0
const fail = m => { console.error('  ✗ ' + m); failures++ }
const ok = m => console.log('  ✓ ' + m)
function setsEqual(a, b, msg) {
  const sa = new Set(a), sb = new Set(b)
  if (sa.size !== sb.size) { fail(`${msg} (数量不符 实际${sa.size} vs 期望${sb.size})`); return }
  for (const x of sa) if (!sb.has(x)) { fail(`${msg} (多出/缺失: ${x})`); return }
  ok(msg)
}

// 收集每页实际 frontmatter
const files = fs.readdirSync(wikiDir).filter(f => f.endsWith('.md'))
const pages = []
for (const f of files) {
  const content = fs.readFileSync(path.join(wikiDir, f), 'utf8')
  const { fmRaw } = splitFrontmatter(content)
  if (!fmRaw) continue
  const fm = parseFrontmatter(fmRaw.split('\n').slice(1, -1).join('\n'))
  if (!Object.keys(fm).length) continue
  pages.push({ file: f, content, fm })
}
console.log(`\n读到 ${pages.length} 个含 frontmatter 的 Wiki 页，逐页校验「只读 banner = 实际键集合」`)

// —— 只读模式：对每一页断言 banner 恰好显示该页的键（不漏、不多、不含来源/概要）——
let checkedTypes = {}
for (const { file, content, fm } of pages) {
  MMEditor.loadMarkdown(content, false)
  const ro = window.document.getElementById('fmBody').innerHTML
  const pageKeys = Object.keys(fm).filter(k => !SKIP[k])
  const bl = fm['backlinks']
  const blHas = bl && (Array.isArray(bl) ? bl.length : String(bl).trim().length)
  // 只读 banner 只对「有值」的键渲染行（与 entry.js fmDisplay / renderFrontmatterBanner 一致）
  const expectedLabels = pageKeys
    .filter(k => (k === 'backlinks' ? !!blHas : dispOf(fm[k]) !== ''))
    .map(labelOf)
  if (expectedLabels.length) {
    if (!ro.includes('<div class="fm-grid">')) { fail(`${file}: 只读 banner 网格未渲染`); continue }
  }
  const roLabels = [...ro.matchAll(/<span class="fm-key">(.*?)<\/span>/g)].map(m => m[1])
  setsEqual(roLabels, expectedLabels, `${file}: 只读 banner 标签集合 == 实际键集合`)
  if (fm['type'] && !ro.includes(String(fm['type']))) fail(`${file}: 只读 banner 未显示 type 值`)
  if (fm['canonical_name'] && !ro.includes(String(fm['canonical_name']))) fail(`${file}: 只读 banner 未显示 canonical_name 值`)
  // 来源/概要 仅是正文章节（## 来源 / ## 概要），不应作为 frontmatter「属性名」出现；
  // 但真实值里包含这些字（如公司简介："…主要来源之一…"）是合法的，故只校验标签集合不含这两个键。
  if (roLabels.includes('来源') || roLabels.includes('概要')) fail(`${file}: 只读 banner 不应以 来源/概要 作为属性名（仅正文章节）`)
  // 记录每个 type 取一个代表页，供可编辑模式校验
  const t = (fm['type'] || '').toLowerCase()
  if (t && !checkedTypes[t]) checkedTypes[t] = { file, content, fm }
}
console.log(`\n只读模式校验完成，覆盖类型: ${Object.keys(checkedTypes).join(', ')}`)

// —— 可编辑模式：对每类取一页，断言表单字段 == 实际键集合（backlinks 只读不编辑）——
for (const t of Object.keys(checkedTypes)) {
  const { file, content, fm } = checkedTypes[t]
  MMEditor.loadMarkdown(content, true)
  const ed = window.document.getElementById('fmBody').innerHTML
  if (!ed.includes('fm-grid edit')) { fail(`${file}: 可编辑表单未渲染`); continue }
  // 标量/下拉/日期/长文本用 data-fm；列表字段（aliases/tags）用 data-add-chip / data-list
  const edFm = [...ed.matchAll(/data-fm="([^"]+)"/g)].map(m => m[1])
  const edList = [...ed.matchAll(/data-add-chip="([^"]+)"/g)].map(m => m[1])
  const edKeys = Array.from(new Set(edFm.concat(edList)))
  const expectedFm = Object.keys(fm).filter(k => !SKIP[k] && k !== 'backlinks')
  setsEqual(edKeys, expectedFm, `${file} (${t}): 可编辑字段集合 == 实际键集合`)
  if (fm['backlinks'] && ed.includes('data-fm="backlinks"')) fail(`${file}: backlinks 不应为可编辑字段`)
  if (fm['公司简介'] && !ed.includes('data-fm="公司简介"')) fail(`${file}: 长文本字段 公司简介 未出现`)
  // Obsidian 风格特征：列表字段渲染为 chip 容器；存在「添加笔记属性」按钮
  for (const lk of ['aliases', 'tags']) {
    if (fm[lk] && !ed.includes(`data-list="${lk}"`)) fail(`${file}: 列表字段 ${lk} 未渲染为 chip 容器`)
  }
  if (!ed.includes('fm-add-prop')) fail(`${file}: 缺少「添加笔记属性」按钮`)
}

if (failures) { console.error(`\n❌ ${failures} 条断言失败`); process.exit(1) }
console.log('\n✅ 全部数据驱动 banner 断言通过（每页只显示其真实 frontmatter 键，无类型猜测、无来源/概要）')
