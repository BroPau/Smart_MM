// ============================================================================
//  Smart Meeting Minutes — TipTap 编辑器核心（离线打包，无外部网络依赖）
//  真·WYSIWYG（Typora 风格）：默认不显示 Markdown 源码符号。
//  双链：[[Page]] / [[Page|alias]] 渲染为可点击 pill；
//        - 缺失页 → 红色虚线下划线（一键创建）
//        - 输入 [[ 自动弹出候选（⌘/↑↓/↵ 选择）
//        - 悬浮预览气泡
//  Markdown 往返：markdown-it（md→html）+ turndown-gfm（html→md）
//  与宿主通过 window.webkit.messageHandlers.editorBridge 通信。
// ============================================================================

import { Editor, Mark, mergeAttributes, markInputRule } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import Placeholder from '@tiptap/extension-placeholder'
import BubbleMenu from '@tiptap/extension-bubble-menu'
import Table from '@tiptap/extension-table'
import TableRow from '@tiptap/extension-table-row'
import TableHeader from '@tiptap/extension-table-header'
import TableCell from '@tiptap/extension-table-cell'
import { Plugin, PluginKey, TextSelection } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import MarkdownIt from 'markdown-it'
import TurndownService from 'turndown'
import { markdownItTable } from 'markdown-it-table'

// ————————————————————————————————————————————————————————————————
//  工具
// ————————————————————————————————————————————————————————————————
function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}
function escapeAttr(s) {
  return escapeHtml(s).replace(/"/g, '&quot;')
}
function isDark() {
  return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches
}

// ————————————————————————————————————————————————————————————————
//  frontmatter 解析（轻量，不依赖 yaml 库；加载时剥离，保存时回贴）
// ————————————————————————————————————————————————————————————————
function splitFrontmatter(md) {
  const L = (md || '').replace(/\r\n/g, '\n').split('\n')
  if (L.length && L[0].trim() === '---') {
    let j = 1
    while (j < L.length && L[j].trim() !== '---') j++
    if (j < L.length) {
      return {
        fmRaw: L.slice(0, j + 1).join('\n'),
        body: L.slice(j + 1).join('\n')
      }
    }
  }
  return { fmRaw: '', body: md || '' }
}
function parseFrontmatter(lines) {
  const fm = {}
  let i = 0
  while (i < lines.length) {
    const s = lines[i]
    const m = s.match(/^([A-Za-z0-9_.\-]+):\s*(.*)$/)
    if (!m) { i++; continue }
    const key = m[1]
    let val = m[2].trim()
    if (val === '') {
      const items = []
      let j = i + 1
      while (j < lines.length) {
        const st = lines[j].match(/^\s+-\s+(.*)$/)
        if (st) { items.push(st[1].trim()); j++; continue }
        break
      }
      if (items.length) fm[key] = items
      i = j
    } else { fm[key] = val; i++ }
  }
  return fm
}
function renderFrontmatterBanner(fm) {
  if (!fm || Object.keys(fm).length === 0) return ''
  const SKIP = { backlinks: 1, wiki_首页: 1 }
  const rows = []
  function addRow(label, value) {
    if (!value) return
    let v = Array.isArray(value) ? value.join('、') : String(value)
    v = v.replace(/^[\[\(](.*)[\]\)]$/, '$1').replace(/^["“”']|["“”']$/g, '')
    if (!v || v === '(空)') return
    rows.push('<tr><th>' + escapeHtml(label) + '</th><td>' + escapeHtml(v) + '</td></tr>')
  }
  const TYPE_LABEL = { person: '👤 人名', company: '🏢 公司', chip: '🔌 芯片', project: '📦 项目', product: '📦 产品', topic: '📚 主题' }
  const tRaw = (fm['type'] || '').toLowerCase()
  addRow('类型', TYPE_LABEL[tRaw] || tRaw || '—')
  const cn = (fm['canonical_name'] || '').toString().trim()
  if (cn) addRow('规范名', cn)
  addRow('别名', fm['aliases']); addRow('公司', fm['company']); addRow('职位', fm['title'])
  addRow('公司类型', fm['公司类型']); addRow('所属行业', fm['所属行业']); addRow('中文名', fm['中文名'])
  addRow('来源', fm['source']); addRow('概要', fm['summary'])
  const tags = fm['tags']
  if (Array.isArray(tags)) {
    const filtered = tags.filter(x => x && x !== 'wiki' && x.toLowerCase() !== tRaw.toLowerCase())
    addRow('标签', filtered)
  }
  addRow('更新', fm['updated'])
  Object.keys(fm).forEach(k => {
    if (SKIP[k.toLowerCase()]) return
    if (['type', 'canonical_name', 'aliases', 'company', 'title', '公司类型', '所属行业', '中文名', 'source', 'summary', 'tags', 'updated'].includes(k)) return
    addRow(k, fm[k])
  })
  if (rows.length === 0) return ''
  return '<table class="fm-table">' + rows.join('') + '</table>'
}

// ————————————————————————————————————————————————————————————————
//  MarkdownIt：把 [[Page]] / [[Page|alias]] 解析为 <a data-wikilink>
// ————————————————————————————————————————————————————————————————
const md = new MarkdownIt({ html: false, linkify: false, breaks: false })
// GFM 管道表格支持：[[Page]] 双链在表格单元格内也可解析（inline 规则）
md.use(markdownItTable)
md.inline.ruler.before('link', 'wikilink', (state, silent) => {
  const start = state.pos
  const src = state.src
  if (src.charCodeAt(start) !== 0x5B) return false
  if (src.charCodeAt(start + 1) !== 0x5B) return false
  const end = src.indexOf(']]', start + 2)
  if (end === -1) return false
  const inner = src.slice(start + 2, end)
  if (inner.includes('[') || inner.includes('\n')) return false
  const seg = inner.split('|')
  const page = (seg[0] || '').trim()
  const alias = (seg[1] || '').trim()
  if (!page) return false
  if (!silent) {
    const token = state.push('wikilink', '', 0)
    token.meta = { page, alias: alias || page }
  }
  state.pos = end + 2
  return true
})
md.renderer.rules.wikilink = (tokens, idx) => {
  const { page, alias } = tokens[idx].meta
  return '<a data-wikilink data-page="' + escapeAttr(page) + '" data-alias="' + escapeAttr(alias) + '" class="wikilink">' + escapeHtml(alias) + '</a>'
}

// ————————————————————————————————————————————————————————————————
//  Turndown：html→md，wikilink / 表格 / 删除线 规则
// ————————————————————————————————————————————————————————————————
const turndownService = new TurndownService({
  headingStyle: 'atx',
  codeBlockStyle: 'fenced',
  bulletListMarker: '-',
  emDelimiter: '*'
})
// GFM 表格（手写，不依赖 turndown-gfm）
turndownService.addRule('gfmTable', {
  filter: 'table',
  replacement: (content, node) => {
    const rows = Array.from(node.querySelectorAll('tr'))
    if (!rows.length) return ''
    const align = []
    Array.from(rows[0].querySelectorAll('th, td')).forEach((c, i) => {
      const s = (c.getAttribute('style') || '').toLowerCase()
      if (s.includes('right')) align[i] = 'right'
      else if (s.includes('center')) align[i] = 'center'
      else align[i] = 'left'
    })
    // 单元格内可能含 [[wikilink]]，必须用 turndown 递归转换（而非 textContent，否则双链在保存时丢失）
    const cellText = cell => turndownService.turndown(cell).replace(/\s*\n\s*/g, ' ').trim()
    const lines = []
    const head = Array.from(rows[0].querySelectorAll('th, td')).map(cellText)
    lines.push('| ' + head.join(' | ') + ' |')
    lines.push('| ' + head.map((_, i) => align[i] === 'right' ? '---:' : align[i] === 'center' ? ':---:' : '---').join(' | ') + ' |')
    for (let r = 1; r < rows.length; r++) {
      const cells = Array.from(rows[r].querySelectorAll('td')).map(cellText)
      lines.push('| ' + cells.join(' | ') + ' |')
    }
    return '\n' + lines.join('\n') + '\n'
  }
})
turndownService.addRule('strikethrough', {
  filter: ['del', 's', 'strike'],
  replacement: content => '~~' + content + '~~'
})
turndownService.addRule('wikilink', {
  filter: node => node.nodeName === 'A' && node.hasAttribute('data-wikilink'),
  replacement: (content, node) => {
    const page = node.getAttribute('data-page') || content
    const alias = node.getAttribute('data-alias')
    if (alias && alias !== page) return '[[' + page + '|' + alias + ']]'
    return '[[' + page + ']]'
  }
})

// ————————————————————————————————————————————————————————————————
//  WikiLink Mark（行内标记）
// ————————————————————————————————————————————————————————————————
const WikiLink = Mark.create({
  name: 'wikilink',
  inclusive: false,
  excludes: '',
  addAttributes() {
    return {
      page: {
        default: null,
        parseHTML: el => el.getAttribute('data-page'),
        renderHTML: attrs => (attrs.page ? { 'data-page': attrs.page } : {})
      },
      alias: {
        default: null,
        parseHTML: el => el.getAttribute('data-alias'),
        renderHTML: attrs => (attrs.alias ? { 'data-alias': attrs.alias } : {})
      }
    }
  },
  parseHTML() {
    return [{ tag: 'a[data-wikilink]' }]
  },
  renderHTML({ HTMLAttributes }) {
    return ['a', mergeAttributes(HTMLAttributes, { 'data-wikilink': '', class: 'wikilink' }), 0]
  },
  addCommands() {
    return {
      setWikiLink: attrs => ({ commands }) => commands.setMark(this.name, attrs)
    }
  },
  addInputRules() {
    return [
      markInputRule({
        find: /\[\[([^\[\]\n]+?)(?:\|([^\[\]\n]+?))?\]\]$/,
        type: this.type,
        getAttributes: m => ({
          page: (m[1] || '').trim(),
          alias: m[2] ? m[2].trim() : null
        })
      })
    ]
  }
})

// ————————————————————————————————————————————————————————————————
//  缺失页装饰插件（根据 window.__wikiPages 给不存在的 wikilink 加红字）
// ————————————————————————————————————————————————————————————————
const missingKey = new PluginKey('wikiMissing')
const missingPlugin = new Plugin({
  key: missingKey,
  props: {
    decorations(state) {
      const known = new Set((window.__wikiPages || []).map(p => p.toLowerCase()))
      const decos = []
      state.doc.descendants((node, pos) => {
        if (!node.isText) return
        node.marks.forEach(mark => {
          if (mark.type.name === 'wikilink' && mark.attrs.page) {
            if (!known.has(mark.attrs.page.toLowerCase())) {
              decos.push(Decoration.inline(pos, pos + node.nodeSize, { class: 'wikilink wikilink-missing' }))
            }
          }
        })
      })
      return DecorationSet.create(state.doc, decos)
    }
  }
})

// ————————————————————————————————————————————————————————————————
//  [[ 自动完成插件（悬浮候选列表）
// ————————————————————————————————————————————————————————————————
const wikiAcKey = new PluginKey('wikiAutocomplete')
let wikiAcViewRef = null

function applyWikiLink(view, page, from, to) {
  const { state } = view
  const markType = state.schema.marks.wikilink
  if (!markType) return
  let tr = state.tr
  tr.delete(from, to)
  const text = page
  tr.insertText(text, from)
  const end = from + text.length
  tr.addMark(from, end, markType.create({ page: page, alias: null }))
  tr.setSelection(TextSelection.create(tr.doc, end))
  view.dispatch(tr)
}

class WikiAutocompleteView {
  constructor(view) {
    this.view = view
    this.index = 0
    this.box = document.createElement('div')
    this.box.className = 'wiki-ac'
    this.box.style.display = 'none'
    view.dom.parentNode.appendChild(this.box)
    this.box.addEventListener('mousedown', e => {
      e.preventDefault()
      const item = e.target.closest && e.target.closest('[data-idx]')
      if (item) this.select(parseInt(item.getAttribute('data-idx'), 10))
    })
  }
  update(view) {
    this.view = view
    const s = wikiAcKey.getState(view.state)
    if (!s || !s.active || s.items.length === 0) { this.box.style.display = 'none'; return }
    if (this.index >= s.items.length) this.index = 0
    let html = ''
    s.items.forEach((it, i) => {
      html += '<div class="wiki-ac-item' + (i === this.index ? ' active' : '') + '" data-idx="' + i + '">' + escapeHtml(it) + '</div>'
    })
    this.box.innerHTML = html
    this.box.style.display = 'block'
    try {
      const coords = view.coordsAtPos(s.from)
      const parentRect = view.dom.parentNode.getBoundingClientRect()
      this.box.style.left = (coords.left - parentRect.left) + 'px'
      this.box.style.top = (coords.bottom - parentRect.top + 4) + 'px'
    } catch (e) {}
  }
  select(i) {
    const s = wikiAcKey.getState(this.view.state)
    if (!s || !s.items[i]) return
    applyWikiLink(this.view, s.items[i], s.from, s.to)
    this.box.style.display = 'none'
    this.index = 0
  }
  destroy() { this.box.remove() }
}

const autocompletePlugin = new Plugin({
  key: wikiAcKey,
  view(editorView) {
    wikiAcViewRef = new WikiAutocompleteView(editorView)
    return wikiAcViewRef
  },
  state: {
    init() { return { active: false, from: 0, to: 0, query: '', items: [] } },
    apply(tr, value, oldState, newState) {
      const sel = newState.selection
      if (!sel.empty) return { active: false, items: [], index: 0 }
      const $from = sel.$from
      const textBefore = $from.parent.textBetween(0, $from.parentOffset, undefined, '￼')
      const m = /\[\[([^\[\]\n]*)$/.exec(textBefore)
      if (!m) return { active: false, items: [], index: 0 }
      const from = $from.pos - m[0].length
      const query = m[1]
      const items = (window.__wikiPages || [])
        .filter(p => p.toLowerCase().includes(query.toLowerCase()))
        .slice(0, 8)
      return { active: true, from, to: sel.to, query, items, index: 0 }
    }
  },
  props: {
    handleKeyDown(view, event) {
      const v = wikiAcViewRef
      if (!v) return false
      const s = wikiAcKey.getState(view.state)
      if (!s || !s.active || s.items.length === 0) return false
      if (event.key === 'ArrowDown') { v.index = (v.index + 1) % s.items.length; v.update(view); return true }
      if (event.key === 'ArrowUp') { v.index = (v.index - 1 + s.items.length) % s.items.length; v.update(view); return true }
      if (event.key === 'Enter' || event.key === 'Tab') { v.select(v.index); return true }
      if (event.key === 'Escape') { v.box.style.display = 'none'; return true }
      return false
    }
  }
})

// ————————————————————————————————————————————————————————————————
//  自动配对 / 自动补全语法符号（引号、括号、单方括号、双方括号等）
// ————————————————————————————————————————————————————————————————
const pairMap = { '"': '"', "'": "'", '(': ')', '[': ']', '{': '}' }
const autoPairKey = new PluginKey('autoPair')
const autoPairPlugin = new Plugin({
  key: autoPairKey,
  props: {
    // 输入成对的左符号时，自动补上右符号并把光标置于中间
    handleTextInput(view, from, to, text) {
      if (!view.editable) return false
      const { state } = view
      if (from !== to) return false  // 有选区时不自动配对，交给默认行为
      const after = state.doc.textBetween(to, to + 2, undefined, '￼')
      const after1 = state.doc.textBetween(to, to + 1, undefined, '￼')
      const before = from > 0 ? state.doc.textBetween(from - 1, from, undefined, '￼') : ''
      // 1) 直接输入 [[ → 自动成对 [[ ]]
      if (text === '[[') {
        const tr = state.tr.insertText('[[]]', from)
        tr.setSelection(TextSelection.create(tr.doc, from + 2))
        view.dispatch(tr.scrollIntoView())
        return true
      }
      // 2) 直接输入 ]] 且后面紧跟 ]] → 跳过（不重复插入）
      if (text === ']]') {
        if (after === ']]') {
          const tr = state.tr.setSelection(TextSelection.create(state.doc, to + 2))
          view.dispatch(tr)
          return true
        }
        return false
      }
      // 3) 单方括号 [
      if (text === '[') {
        if (after1 === '[') {
          // 第二个 [ 已存在，补全 ]]
          const tr = state.tr.insertText(']]', to)
          tr.setSelection(TextSelection.create(tr.doc, to))
          view.dispatch(tr.scrollIntoView())
          return true
        }
        if (after1 === ']' && before === '[') {
          // 在自动成对的 [ ] 内补成 [[ ]]
          const tr = state.tr.insertText('[', from)
          tr.insertText(']', from + 2)
          tr.setSelection(TextSelection.create(tr.doc, from + 2))
          view.dispatch(tr.scrollIntoView())
          return true
        }
        const tr = state.tr.insertText('[]', from)
        tr.setSelection(TextSelection.create(tr.doc, from + 1))
        view.dispatch(tr.scrollIntoView())
        return true
      }
      // 4) 单方括号 ] → 若后面已是 ]，跳过
      if (text === ']') {
        if (after1 === ']') {
          const tr = state.tr.setSelection(TextSelection.create(state.doc, to + 1))
          view.dispatch(tr)
          return true
        }
        return false
      }
      // 5) 其余成对符号（" ' ( { ）
      if (pairMap[text]) {
        const close = pairMap[text]
        const tr = state.tr.insertText(text + close, from)
        tr.setSelection(TextSelection.create(tr.doc, from + 1))
        view.dispatch(tr.scrollIntoView())
        return true
      }
      return false
    },
    // 输入右符号且光标后已是其配对字符时，直接跳过后跳过（不重复插入）
    handleKeyDown(view, event) {
      if (!view.editable) return false
      const skip = { ')': ')', ']': ']', '}': '}', '"': '"', "'": "'" }
      if (skip[event.key]) {
        const { state } = view
        const sel = state.selection
        if (sel.empty) {
          const after = state.doc.textBetween(sel.to, sel.to + 1, undefined, '￼')
          if (after === event.key) {
            const tr = state.tr.setSelection(TextSelection.create(state.doc, sel.to + 1))
            view.dispatch(tr)
            return true
          }
        }
      }
      return false
    }
  }
})

// ————————————————————————————————————————————————————————————————
//  自动双链：把正文里出现的已知 Wiki 页名裸词包裹为 [[名称]]
// ————————————————————————————————————————————————————————————————
function autoLinkWiki(body, names) {
  if (!names || !names.length) return body
  const sorted = names.filter(Boolean).slice().sort((a, b) => b.length - a.length)
  const lines = body.split('\n')
  let out = ''
  let inFence = false
  for (let li = 0; li < lines.length; li++) {
    let line = lines[li]
    // 跳过围栏代码块（``` / ~~~）
    if (/^\s*(```|~~~)/.test(line)) { inFence = !inFence; out += line + '\n'; continue }
    if (inFence) { out += line + '\n'; continue }
    out += autoLinkLine(line, sorted) + '\n'
  }
  return out
}
function autoLinkLine(line, sorted) {
  const protectedChunks = []
  let s = line
  // 保护：行内代码 `...`，避免把代码里的词也链接
  s = s.replace(/`[^`]*`/g, m => { protectedChunks.push(m); return '\u0000' + (protectedChunks.length - 1) + '\u0000' })
  // 保护：已有的标准链接 [text](url) 与双链 [[...]]，避免重复包裹
  s = s.replace(/\[[^\]]*\]\([^)]*\)/g, m => { protectedChunks.push(m); return '\u0000' + (protectedChunks.length - 1) + '\u0000' })
  s = s.replace(/\[\[[^\]]*\]\]/g, m => { protectedChunks.push(m); return '\u0000' + (protectedChunks.length - 1) + '\u0000' })
  // 包裹已知名称（长名优先）
  for (const name of sorted) {
    const esc = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const re = new RegExp(esc, 'g')
    s = s.replace(re, '[[$&]]')
    // 重新保护刚生成的 [[名称]]，避免更短的名称在长名结果内被二次包裹
    s = s.replace(/\[\[[^\]]*\]\]/g, m => { protectedChunks.push(m); return '\u0000' + (protectedChunks.length - 1) + '\u0000' })
  }
  // 还原被保护的片段
  s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => protectedChunks[Number(i)])
  return s
}

// ————————————————————————————————————————————————————————————————
//  悬浮预览气泡
// ————————————————————————————————————————————————————————————————
let previewEl = null
let previewHideTimer = null
let previewActiveName = null

function ensurePreviewEl() {
  if (previewEl) return previewEl
  previewEl = document.createElement('div')
  previewEl.id = 'wikiPreview'
  previewEl.className = 'wiki-preview'
  previewEl.style.display = 'none'
  document.body.appendChild(previewEl)
  previewEl.addEventListener('mouseenter', () => { if (previewHideTimer) clearTimeout(previewHideTimer) })
  previewEl.addEventListener('mouseleave', () => { hidePreviewSoon() })
  return previewEl
}
function hidePreviewSoon() {
  if (previewHideTimer) clearTimeout(previewHideTimer)
  previewHideTimer = setTimeout(() => { if (previewEl) previewEl.style.display = 'none' }, 220)
}
function showPreviewFor(el) {
  const name = el.getAttribute('data-page')
  if (!name) return
  const pv = ensurePreviewEl()
  previewActiveName = name
  const rect = el.getBoundingClientRect()
  pv.style.display = 'block'
  pv.innerHTML = '<div class="wiki-preview-loading">加载预览…</div>'
  pv.style.left = Math.max(8, rect.left) + 'px'
  pv.style.top = (rect.bottom + 8) + 'px'
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
    window.webkit.messageHandlers.editorBridge.postMessage({ type: 'wikilinkPreview', name: name })
  }
}
function hidePreview() { if (previewEl) previewEl.style.display = 'none' }

// 宿主回填预览内容
window.MMEditor_showPreview = function (name, html) {
  if (previewActiveName !== name) return
  const pv = ensurePreviewEl()
  if (!html) {
    pv.innerHTML = '<div class="wiki-preview-body"><div class="wiki-preview-missing">📄 此页面尚不存在<br><span class="wiki-preview-hint">点击链接或按 ⌘+Click 即可创建</span></div></div>'
  } else {
    pv.innerHTML = '<div class="wiki-preview-body">' + html + '</div>'
  }
  pv.style.display = 'block'
}

// ————————————————————————————————————————————————————————————————
//  编辑器实例
// ————————————————————————————————————————————————————————————————
let editor = null
let pendingFrontmatter = ''
let currentFM = {}
let currentEditable = true

function buildEditor(editable) {
  if (editor) { editor.destroy(); editor = null }
  editor = new Editor({
    element: document.getElementById('editor'),
    extensions: [
      // 启用标准 Markdown 链接 [text](url)（关闭点击跳转/自动链接，编辑体验更可控）
      StarterKit.configure({ link: { openOnClick: false, autolink: false, linkOnPaste: false } }),
      Placeholder.configure({ placeholder: '输入正文，或输入 [[ 关联其他页面…' }),
      WikiLink,
      Table.configure({ resizable: true }),
      TableRow,
      TableHeader,
      TableCell,
      BubbleMenu.configure({
        element: getBubbleMenuEl(),
        shouldShow: ({ editor, from, to }) => from !== to && !editor.isActive('wikilink')
      }),
      {
        addProseMirrorPlugins() { return [missingPlugin] }
      },
      {
        addProseMirrorPlugins() { return [autocompletePlugin] }
      },
      {
        addProseMirrorPlugins() { return [autoPairPlugin] }
      }
    ],
    editable: editable,
    autofocus: false,
    content: '',
    editorProps: {
      attributes: { class: 'mm-tiptap' }
    },
    onUpdate: () => {
      // 注意：缺失页装饰由 ProseMirror 在每次状态变化时自动重算，
      // 这里切勿再 dispatch 事务，否则会触发 onUpdate → 再 dispatch 的死循环。
    }
  })
  wireEditorDom()
}

function getBubbleMenuEl() {
  let el = document.getElementById('bubbleMenu')
  if (!el) {
    el = document.createElement('div')
    el.id = 'bubbleMenu'
    el.style.display = 'none'
    document.body.appendChild(el)
    el.innerHTML =
      '<button data-cmd="bold">B</button>' +
      '<button data-cmd="italic">I</button>' +
      '<button data-cmd="strike">S</button>' +
      '<button data-cmd="code">⟨⟩</button>' +
      '<button data-cmd="h1">H1</button>' +
      '<button data-cmd="h2">H2</button>' +
      '<button data-cmd="bulletList">• 列表</button>' +
      '<button data-cmd="orderedList">1. 列表</button>' +
      '<button data-cmd="blockquote">❝</button>'
    el.addEventListener('mousedown', e => {
      e.preventDefault()
      const btn = e.target.closest && e.target.closest('button[data-cmd]')
      if (!btn || !editor) return
      const cmd = btn.getAttribute('data-cmd')
      const map = {
        bold: () => editor.chain().focus().toggleBold().run(),
        italic: () => editor.chain().focus().toggleItalic().run(),
        strike: () => editor.chain().focus().toggleStrike().run(),
        code: () => editor.chain().focus().toggleCode().run(),
        h1: () => editor.chain().focus().toggleHeading({ level: 1 }).run(),
        h2: () => editor.chain().focus().toggleHeading({ level: 2 }).run(),
        bulletList: () => editor.chain().focus().toggleBulletList().run(),
        orderedList: () => editor.chain().focus().toggleOrderedList().run(),
        blockquote: () => editor.chain().focus().toggleBlockquote().run()
      }
      if (map[cmd]) map[cmd]()
    })
  }
  return el
}

function wireEditorDom() {
  const dom = editor.view.dom
  dom.addEventListener('mouseover', e => {
    const el = e.target.closest && e.target.closest('a.wikilink')
    if (el) showPreviewFor(el)
  })
  dom.addEventListener('mouseout', e => {
    const el = e.target.closest && e.target.closest('a.wikilink')
    if (el) hidePreviewSoon()
  })
  dom.addEventListener('click', e => {
    const el = e.target.closest && e.target.closest('a.wikilink')
    if (el) {
      e.preventDefault()
      const name = el.getAttribute('data-page')
      if (name && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
        window.webkit.messageHandlers.editorBridge.postMessage({ type: 'wikilink', name: name })
      }
    }
  })
}

// ————————————————————————————————————————————————————————————————
//  公开 API（供 Swift 的 WKWebView 调用）
// ————————————————————————————————————————————————————————————————
window.MMEditor = {
  init() {
    buildEditor(true)
  },
  loadMarkdown(mdText, editable, mode, autoLink) {
    const sp = splitFrontmatter(mdText || '')
    pendingFrontmatter = sp.fmRaw
    currentFM = sp.fmRaw ? parseFrontmatter(sp.fmRaw.split('\n').slice(1, -1)) : {}
    currentEditable = editable !== false
    // 顶部属性 banner：属性表单**始终内联可编辑**（与正文同处一个编辑器窗口），
    // 不再需要"编辑属性"按钮，也不再弹独立窗口。只读场景（搜索结果）仍展示只读表。
    renderBanner()
    // 拉取宿主侧的自定义类型（共享自 custom_types.json），并入类型下拉
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
      window.webkit.messageHandlers.editorBridge.postMessage({ type: 'getCustomTypes' })
    }
    // 自动双链：加载单人纪要时，把正文里出现的已知 Wiki 页名裸词包裹成 [[名称]]（点击即跳 Wiki）
    let body = sp.body || ''
    if (autoLink && window.__autoLinkNames && window.__autoLinkNames.length) {
      body = autoLinkWiki(body, window.__autoLinkNames)
    }
    // md → html → 编辑器
    const html = md.render(body)
    if (!editor) buildEditor(editable !== false)
    editor.commands.setContent(html, false)
    editor.setEditable(editable !== false)
    // 刷新缺失页装饰
    editor.view.dispatch(editor.state.tr.setMeta(missingKey, { recompute: true }))
  },
  requestSave() {
    if (!editor) return
    const html = editor.getHTML()
    let body = turndownService.turndown(html)
    body = body.replace(/\n{3,}/g, '\n\n').replace(/[ \t]+$/gm, '')
    const out = (pendingFrontmatter ? pendingFrontmatter + '\n' : '') + body
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
      window.webkit.messageHandlers.editorBridge.postMessage({ type: 'save', markdown: out.trimEnd() })
    }
  },
  /// 取出"当前页面的完整 Markdown（含 frontmatter）"，用于宿主侧属性编辑面板预填。
  requestCurrentMarkdown() {
    if (!editor) return pendingFrontmatter || ''
    const html = editor.getHTML()
    let body = turndownService.turndown(html)
    body = body.replace(/\n{3,}/g, '\n\n').replace(/[ \t]+$/gm, '')
    return (pendingFrontmatter ? pendingFrontmatter + '\n' : '') + body.trimEnd()
  },
  setMode() { /* TipTap 始终为真·WYSIWYG，无需切换 */ },
  setWikiPages(arr) {
    window.__wikiPages = Array.isArray(arr) ? arr : []
    if (editor) editor.view.dispatch(editor.state.tr.setMeta(missingKey, { recompute: true }))
  },
  // 推送「自动双链」目标名（仅 Wiki 页名），加载纪要时把裸词包裹成 [[名称]]
  setAutoLinkNames(arr) {
    window.__autoLinkNames = Array.isArray(arr) ? arr : []
  },
  // 宿主下发自定义类型列表（共享自 custom_types.json），并入类型下拉；可选 selectName 自动选中新类型
  setCustomTypes(arr, selectName) {
    CUSTOM_TYPES = Array.isArray(arr) ? arr : []
    renderBanner()
    if (selectName) {
      const sel = document.querySelector('select[data-fm="type"]')
      if (sel) { sel.value = selectName; sel.dispatchEvent(new Event('change', { bubbles: true })) }
    }
  },
  showPreview(name, html) { window.MMEditor_showPreview(name, html) }
}

// ⌘S 保存
document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
    e.preventDefault()
    window.MMEditor.requestSave()
  }
})

// 顶部属性 banner：属性表单**始终内联可编辑**（与正文同处一个编辑器窗口）。
// 不再有"编辑属性"按钮，也不再弹独立窗口；任意字段改动即自动写回 frontmatter 并保存。
let CUSTOM_TYPES = []  // 宿主下发的自定义类型（来自 custom_types.json），并入类型下拉
function renderBanner() {
  const det = document.getElementById('fmBanner')
  const body = document.getElementById('fmBody')
  if (!det || !body) return
  if (!currentFM || Object.keys(currentFM).length === 0) {
    det.style.display = 'none'
    body.innerHTML = ''
    return
  }
  det.style.display = ''
  det.open = true
  if (currentEditable) {
    body.innerHTML = renderBannerEditForm(currentFM)
    wireBannerForm(body)
  } else {
    const html = renderFrontmatterBanner(currentFM)
    if (html) { body.innerHTML = html } else { det.style.display = 'none'; body.innerHTML = '' }
  }
}

// 给表单每个 [data-fm] 字段绑定 input/change：实时写回 currentFM + pendingFrontmatter，
// 并防抖 400ms 后自动 requestSave（宿主落盘）。无需任何按钮。
let _bannerSaveTimer = null
function wireBannerForm(root) {
  if (!root) return
  root.querySelectorAll('[data-fm]').forEach(el => {
    const onEdit = () => {
      const k = el.getAttribute('data-fm')
      const kind = el.getAttribute('data-kind')
      const v = el.value
      if (kind === 'list') {
        currentFM[k] = v.split(/[,，、]/).map(s => s.trim()).filter(Boolean)
      } else {
        currentFM[k] = v.trim()
      }
      pendingFrontmatter = serializeFrontmatter(currentFM)
      if (_bannerSaveTimer) clearTimeout(_bannerSaveTimer)
      _bannerSaveTimer = setTimeout(() => {
        if (window.MMEditor && window.MMEditor.requestSave) window.MMEditor.requestSave()
      }, 400)
    }
    el.addEventListener('input', onEdit)
    el.addEventListener('change', onEdit)
  })
  root.querySelectorAll('[data-addtype]').forEach(btn => {
    btn.addEventListener('click', () => {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
        window.webkit.messageHandlers.editorBridge.postMessage({ type: 'addCustomType' })
      }
    })
  })
}

function renderBannerEditForm(fm) {
  const FIELDS = [
    { key: 'type', label: '类型', kind: 'select' },
    { key: 'canonical_name', label: '规范名', kind: 'text' },
    { key: 'aliases', label: '别名', kind: 'list' },
    { key: 'company', label: '公司', kind: 'text' },
    { key: 'title', label: '职位', kind: 'text' },
    { key: '公司类型', label: '公司类型', kind: 'text' },
    { key: '所属行业', label: '所属行业', kind: 'text' },
    { key: '中文名', label: '中文名', kind: 'text' },
    { key: 'source', label: '来源', kind: 'text' },
    { key: 'summary', label: '概要', kind: 'textarea' },
    { key: 'tags', label: '标签', kind: 'list' },
    { key: 'updated', label: '更新', kind: 'text' }
  ]
  const SKIP = { backlinks: 1, 'wiki_首页': 1, type: 1, canonical_name: 1, aliases: 1, company: 1, title: 1, '公司类型': 1, '所属行业': 1, '中文名': 1, source: 1, summary: 1, tags: 1, updated: 1 }
  let html = '<div class="fm-edit-form">'
  FIELDS.forEach(f => {
    const raw = fm[f.key]
    const val = Array.isArray(raw) ? raw.join(', ') : (raw == null ? '' : String(raw))
    html += '<div class="fm-field"><label>' + escapeHtml(f.label) + '</label>'
    if (f.kind === 'select') {
      const builtin = ['person', 'company', 'chip', 'project', 'product', 'topic']
      const opts = builtin.concat(CUSTOM_TYPES.filter(t => !builtin.includes(t)))
      html += '<div class="fm-type-row"><select data-fm="' + f.key + '" data-kind="scalar">' +
        opts.map(o => '<option value="' + o + '"' + (String(raw) === o ? ' selected' : '') + '>' + o + '</option>').join('') + '</select>' +
        '<button type="button" data-addtype="1" class="fm-addtype" title="新增自定义类型（共享到所有 Wiki 页）">＋</button></div>'
    } else if (f.kind === 'textarea') {
      html += '<textarea data-fm="' + f.key + '" data-kind="scalar">' + escapeHtml(val) + '</textarea>'
    } else {
      const kind = f.kind === 'list' ? 'list' : 'scalar'
      html += '<input type="text" data-fm="' + f.key + '" data-kind="' + kind + '" value="' + escapeAttr(val) + '">'
    }
    html += '</div>'
  })
  // 未知额外字段（除托管字段外）也一并可编辑
  Object.keys(fm).forEach(k => {
    if (SKIP[k]) return
    const raw = fm[k]
    const val = Array.isArray(raw) ? raw.join(', ') : (raw == null ? '' : String(raw))
    html += '<div class="fm-field"><label>' + escapeHtml(k) + '</label>' +
      '<input type="text" data-fm="' + escapeAttr(k) + '" data-kind="scalar" value="' + escapeAttr(val) + '"></div>'
  })
  html += '</div>'
  return html
}

function serializeFrontmatter(fm) {
  if (!fm || Object.keys(fm).length === 0) return ''
  const lines = ['---']
  Object.keys(fm).forEach(k => {
    const v = fm[k]
    if (v === undefined || v === null) return
    if (Array.isArray(v)) {
      if (v.length === 0) { lines.push(k + ': []'); return }
      lines.push(k + ':')
      v.forEach(item => lines.push('  - ' + yamlScalar(item)))
    } else {
      const s = String(v)
      if (s === '') { lines.push(k + ': ""'); return }
      lines.push(k + ': ' + yamlScalar(s))
    }
  })
  lines.push('---')
  return lines.join('\n')
}

function yamlScalar(s) {
  s = String(s).replace(/\r?\n/g, ' ')
  if (/[:#\[\]{}",]/.test(s) || /^ | $/.test(s) || /^[!\-*?&|>#%@`]/.test(s)) {
    return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'
  }
  return s
}

// 跟随系统深色模式：重建编辑器以拾取 CSS 变量
if (window.matchMedia) {
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (editor) {
      const editable = editor.isEditable
      const html = editor.getHTML()
      buildEditor(editable)
      editor.commands.setContent(html, false)
    }
  })
}
