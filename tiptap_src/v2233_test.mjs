// v2.2.33 banner smoke test: 测真实 wiki page frontmatter → label 顺序
// - Person: 类型 → 规范名 → 别名 → [中文名/公司/职位/职能范围] → 标签 → 更新时间 → 反向链接
// - Company: 类型 → 规范名 → 别名 → [公司类型/所属行业/公司简介] → 标签 → 更新时间 → 反向链接
// - Chip: 类型 → 规范名 → 别名 → [品牌/具体型号/类别/功能简述/状态/替代料] → 标签 → 更新时间 → 反向链接
import { JSDOM } from 'jsdom'
import fs from 'fs'
import path from 'path'

const BUNDLE = '/Users/weilu/Downloads/ShareFolder/Meetinsight/Meetinsight/tiptap/tiptap.bundle.js'
const WIKI_DIR = '/Users/weilu/Downloads/ShareFolder/Meeting_Minutes/005_LLMWiKi/wiki_pages'

const tiptapSrc = new URL('.', import.meta.url).pathname
const bundlePath = path.resolve(tiptapSrc, '../tiptap/tiptap.bundle.js')
if (!fs.existsSync(bundlePath)) { console.error('FAIL: bundle missing'); process.exit(1) }

const dom = new JSDOM(`<!DOCTYPE html><html><body>
<details id="fmBanner"><summary>banner</summary><div id="fmBody"></div></details>
<div id="editor"></div>
</body></html>`, { runScripts: 'outside-only', pretendToBeVisual: true })
const { window } = dom
window.matchMedia = window.matchMedia || (() => ({ matches: false, addEventListener() {}, removeEventListener() {} }))
const code = fs.readFileSync(bundlePath, 'utf8')
const fn = new Function('window', 'document', 'navigator', 'DOMParser', 'Node', 'NodeFilter', 'getComputedStyle', code + '\n;return window.MMEditor;')
const MMEditor = fn(window, window.document, window.navigator, window.DOMParser, window.Node, window.NodeFilter, window.getComputedStyle.bind(window))
MMEditor.init()

function extractLabelOrder(html) {
  // 抓 .fm-row 里的 .fm-key (label)
  const re = /<div class="fm-row[\s\S]*?<span class="fm-key[^"]*">([^<]+)<\/span>[\s\S]*?<\/div>/g
  const labels = []
  let m
  while ((m = re.exec(html)) !== null) labels.push(m[1].trim())
  return labels
}

let failures = 0
const fail = m => { console.error('  ✗ ' + m); failures++ }
const ok = m => console.log('  ✓ ' + m)

async function testFile(name, expectedOrder) {
  const md = fs.readFileSync(path.join(WIKI_DIR, name), 'utf8')
  MMEditor.loadMarkdown(md, false)
  const html = window.document.getElementById('fmBody').innerHTML
  const actual = extractLabelOrder(html)
  console.log(`\n=== ${name} ===`)
  console.log('  Actual:', actual.join(' → '))
  // 检查顺序约束：expectedOrder 中已出现的项必须按 expectedOrder 出现
  let actualIdx = 0
  for (const exp of expectedOrder) {
    // 在 actual 中跳过不期待的（page 没有这个字段就不会出现）
    while (actualIdx < actual.length && actual[actualIdx] !== exp) actualIdx++
    if (actualIdx >= actual.length) {
      // 字段不在 actual 中（page 没有），跳过
      continue
    }
    // 找到了，OK
  }
  // 验证：expectedOrder 的子集如果在 actual 中，必须按 expected 的顺序
  const filteredExpected = expectedOrder.filter(e => actual.includes(e))
  let lastIdx = -1
  let ordered = true
  for (const exp of filteredExpected) {
    const idx = actual.indexOf(exp)
    if (idx < lastIdx) { ordered = false; break }
    lastIdx = idx
  }
  if (ordered) ok(`${name} 顺序与约定一致`)
  else fail(`${name} 顺序乱: ${actual.join(' → ')}`)
}

await testFile('MCXN947.md', ['类型', '规范名', '别名', '品牌', '具体型号', '类别', '功能简述', '状态', '替代料', '标签', '更新时间', '反向链接'])
await testFile('刘玲.md', ['类型', '规范名', '别名', '公司', '职位', '职能范围', '标签', '更新时间', '反向链接'])
await testFile('NXP（恩智浦半导体）.md', ['类型', '规范名', '别名', '标签', '更新时间', '反向链接'])

if (failures) { console.error(`\n❌ ${failures} 条断言失败`); process.exit(1) }
console.log('\n✅ v2.2.33 banner 顺序冒烟测试全绿')
