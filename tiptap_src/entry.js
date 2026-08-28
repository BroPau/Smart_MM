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

import { Editor, Mark, Extension, mergeAttributes, markPasteRule } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import Placeholder from '@tiptap/extension-placeholder'
import BubbleMenu from '@tiptap/extension-bubble-menu'
import Table from '@tiptap/extension-table'
import TableRow from '@tiptap/extension-table-row'
import TableHeader from '@tiptap/extension-table-header'
import TableCell from '@tiptap/extension-table-cell'
import TaskList from '@tiptap/extension-task-list'
import TaskItem from '@tiptap/extension-task-item'
import { Plugin, PluginKey, TextSelection } from '@tiptap/pm/state'
import { liftListItem } from '@tiptap/pm/schema-list'
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

// ————————————————————————————————————————————————————————————————
//  MarkdownIt：把 [[Page]] / [[Page|alias]] 解析为 <a data-wikilink>
// ————————————————————————————————————————————————————————————————
const md = new MarkdownIt({ html: false, linkify: false, breaks: false })
// GFM 管道表格支持：[[Page]] 双链在表格单元格内也可解析（inline 规则）
md.use(markdownItTable)
// GFM 任务列表：- [ ] 未完成 / - [x] 已完成 → TipTap taskList/taskItem（可勾选）
md.use(taskListsPlugin)
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
  const target = (seg[0] || '').trim()
  const alias = (seg[1] || '').trim()
  if (!target) return false
  // Obsidian 式锚点：[[Page#Heading]] / [[Page#^blockId]]（同页可省略 Page，写成 [[#Heading]]）
  let page = target
  let anchor = ''
  const h = target.indexOf('#')
  if (h >= 0) {
    page = target.slice(0, h).trim()
    anchor = target.slice(h + 1).trim()
    // 同页锚点 [[#Heading]]：page 为空时，用当前页名兜底（宿主在 loadMarkdown 时下发），
    // 这样渲染出的 data-page = 当前页、data-anchor = 标题，点击时宿主能正确判定「当前页 + 滚动到标题」。
    if (page.length === 0) page = (window.__currentPageName || anchor)
  }
  if (!page) return false
  if (!silent) {
    const token = state.push('wikilink', '', 0)
    token.meta = { page, anchor, alias: alias || page }
  }
  state.pos = end + 2
  return true
})
md.renderer.rules.wikilink = (tokens, idx) => {
  const { page, anchor, alias } = tokens[idx].meta
  const anchorAttr = anchor ? ' data-anchor="' + escapeAttr(anchor) + '"' : ''
  return '<a data-wikilink data-page="' + escapeAttr(page) + '" data-alias="' + escapeAttr(alias) + '"' + anchorAttr + ' class="wikilink">' + escapeHtml(alias) + '</a>'
}

// GFM 任务列表解析：- [ ] / - [x] / - [X] 开头的列表项 → TipTap taskList/taskItem。
// 只要列表中「任一项」是任务项，就把整张列表转成 taskList，且所有项都作为 taskItem
// （非任务项默认未勾选）。这样既不丢数据（普通项保留为未勾选），也满足 TaskList 的
// 内容必须是 taskItem+ 的 schema 约束，不会在加载/保存时崩溃。
function taskListsPlugin(md) {
  md.core.ruler.push('gfm_task_lists', state => {
    const tokens = state.tokens
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].type !== 'bullet_list_open') continue
      // 收集该 bullet_list 内的所有 list_item_open 索引
      let j = i + 1
      const itemOpens = []
      while (j < tokens.length && tokens[j].type !== 'bullet_list_close') {
        if (tokens[j].type === 'list_item_open') itemOpens.push(j)
        j++
      }
      if (itemOpens.length === 0) continue
      const checkedFlags = []
      let anyTask = false
      for (const io of itemOpens) {
        let k = io + 1
        let detected = false
        let checked = false
        while (k < tokens.length && tokens[k].type !== 'list_item_close') {
          if (tokens[k].type === 'inline') {
            const t = tokens[k]
            const m = /^\s*\[([ xX])\]\s+/.exec(t.content || '')
            let cm = null
            if (t.children && t.children.length && t.children[0].type === 'text') {
              cm = /^\s*\[([ xX])\]\s+/.exec(t.children[0].content || '')
            }
            if (m && cm) {
              detected = true
              checked = cm[1].toLowerCase() === 'x'
              // 去掉正文里的 [ ] 前缀（渲染用 children，故改 children[0]）
              t.children[0].content = t.children[0].content.slice(cm[0].length)
              t.content = (t.content || '').slice(m[0].length)
            }
            break
          }
          k++
        }
        if (detected) anyTask = true
        checkedFlags.push(checked)
      }
      if (anyTask) {
        tokens[i].attrSet('data-type', 'taskList')
        itemOpens.forEach((io, idx) => {
          tokens[io].attrSet('data-type', 'taskItem')
          tokens[io].attrSet('data-checked', checkedFlags[idx] ? 'true' : 'false')
        })
      }
    }
  })
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
    const anchor = node.getAttribute('data-anchor') || ''
    const head = page + (anchor ? '#' + anchor : '')
    if (alias && alias !== page) return '[[' + head + '|' + alias + ']]'
    return '[[' + head + ']]'
  }
})
// 统一覆盖 turndown 默认的 listItem（其硬编码 bulletListMarker + '   ' 三空格缩进，
// 且完全忽略 listItemIndent 选项）。本规则：普通项用「- 」单空格，有序项用「N. 」单空格，
// 并支持 GFM 任务列表 <li data-type="taskItem"> → - [ ] / - [x]。
turndownService.addRule('listItem', {
  filter: 'li',
  replacement: (content, node, options) => {
    let prefix
    if (node.getAttribute('data-type') === 'taskItem') {
      const checked = node.getAttribute('data-checked') === 'true' || node.getAttribute('data-checked') === ''
      prefix = '- ' + (checked ? '[x] ' : '[ ] ')
    } else {
      prefix = options.bulletListMarker + ' '
      const parent = node.parentNode
      if (parent && parent.nodeName === 'OL') {
        const start = parent.getAttribute('start')
        const index = Array.prototype.indexOf.call(parent.children, node)
        prefix = (start ? Number(start) + index : index + 1) + '. '
      }
    }
    const isParagraph = /\n$/.test(content)
    content = content.replace(/^\n+/, '').replace(/\n+$/, '') + (isParagraph ? '\n' : '')
    content = content.replace(/\n/gm, '\n' + ' '.repeat(prefix.length))
    return prefix + content + (node.nextSibling ? '\n' : '')
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
      anchor: {
        default: null,
        parseHTML: el => el.getAttribute('data-anchor'),
        renderHTML: attrs => (attrs.anchor ? { 'data-anchor': attrs.anchor } : {})
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
  addPasteRules() {
    // 粘贴场景：[[Page]] / [[Page|alias]] 直接渲染为 wikilink（保留 [[]] 源码符号）。
    // 键入场景不在此处理——由 autoPairPlugin 在输入 ]] 时调用 autoRenderWikiLink 自动渲染
    // （并去掉 [[]] 源码符号，与自动补全候选行为一致），避免与 autoPair 的 handleTextInput 冲突。
    return [
      markPasteRule({
        find: /\[\[([^\[\]\n]+?)(?:\|([^\[\]\n]+?))?\]\]/g,
        type: this.type,
        getAttributes: m => {
          const target = (m[1] || '').trim()
          let page = target, anchor = ''
          const h = target.indexOf('#')
          if (h >= 0) { page = target.slice(0, h).trim(); anchor = target.slice(h + 1).trim() }
          return { page, anchor: anchor || null, alias: m[2] ? m[2].trim() : null }
        }
      })
    ]
  }
})

// ————————————————————————————————————————————————————————————————
//  列表项 Backspace 直接 dedent（仿 Obsidian / Typora）
//  行为：光标位于嵌套列表项（bullet / ordered / task）开头时，Backspace 直接提升一级
//        （与 Shift+Tab 等价）；顶层列表项退回默认合并行为，避免误删正文。
// ————————————————————————————————————————————————————————————————
const ListBackspace = Extension.create({
  name: 'listBackspace',
  addKeyboardShortcuts() {
    return {
      Backspace: ({ editor }) => {
        const { state } = editor
        const { selection } = state
        if (!selection.empty) return false
        const $from = selection.$from
        if ($from.parentOffset !== 0) return false
        const paraDepth = $from.depth
        const itemNode = paraDepth >= 2 ? $from.node(paraDepth - 1) : null
        if (!itemNode || (itemNode.type.name !== 'listItem' && itemNode.type.name !== 'taskItem')) return false
        const listNode = paraDepth >= 3 ? $from.node(paraDepth - 2) : null
        if (!listNode || !['bulletList', 'orderedList', 'taskList'].includes(listNode.type.name)) return false
        // 仅当该列表项确实嵌套在另一个列表项内时才拦截 Backspace（dedent）；
        // 顶层列表项交给默认行为（与上一块合并），避免破坏正文。
        const grandParent = paraDepth >= 4 ? $from.node(paraDepth - 3) : null
        const isNested = !!grandParent && (grandParent.type.name === 'listItem' || grandParent.type.name === 'taskItem')
        if (!isNested) return false
        return liftListItem(itemNode.type)(state, editor.view.dispatch)
      }
    }
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
  // 解析锚点：把「同页锚点」与「跨页锚点」统一拆成 干净的 page 名 + anchor 标题，
  // 分别写入 wikilink mark 的 page / anchor 属性（data-page 只存页名、data-anchor 只存标题）。
  // —— 这样 turndown 保存时会拼成 [[Page#Heading]]，点击时宿主也能正确 split，不会误当独立页。
  let anchor = null
  let display = page
  if (typeof page === 'string') {
    if (page.charAt(0) === '#') {
      // 同页锚点：[[#Heading]]（Obsidian 式段内跳转）—补上当前页名。
      const heading = page.slice(1).trim()
      const cur = (window.__currentPageName || '').trim()
      anchor = heading
      display = heading                 // 同页锚点正文只显示标题
      page = cur || heading            // 无当前页名兜底（极少见，如搜索结果视图）：退化为纯标题
    } else {
      // 跨页锚点：Page#Heading（理论上自动补全不会直接给这种值，但手动/粘贴路径可能进入）
      const h = page.indexOf('#')
      if (h >= 0) {
        anchor = page.slice(h + 1).trim()
        page = page.slice(0, h).trim() // page 只保留页名，anchor 单独存
        if (!anchor) anchor = null
      }
    }
  }
  let tr = state.tr
  // 1) 删除 [[query（光标前到 [[ 起始位置）
  tr = tr.delete(from, to)
  // 2) 插入可见文本（覆盖原 [[query）
  const text = display
  tr = tr.insertText(text, from)
  const end = from + text.length
  // 3) 同步消耗紧随其后的 ]]（autoPair 自动插入的双方括号闭合符）。
  //    原文档：[[query]]  删 from..to 后只剩 ]]  插 text 后变成 text]]
  //    删 end..end+2 让 wikilink 干净收尾，光标落在链接末尾而不是 ]] 之前。
  if (end + 2 <= tr.doc.content.size) {
    const after = tr.doc.textBetween(end, Math.min(end + 2, tr.doc.content.size), undefined, '￼')
    if (after === ']]') {
      tr = tr.delete(end, end + 2)
    }
  }
  tr = tr.addMark(from, end, markType.create({ page: page, anchor: anchor || null, alias: null }))
  tr = tr.setSelection(TextSelection.create(tr.doc, end))
  view.dispatch(tr)
}

// 手动键入 [[Page]] / [[Page|alias]] 完成后，自动把整段转为 wikilink mark（Obsidian 式「输入双方括号即自动渲染」）。
// 与自动补全候选行为一致：去掉 [[]] 源码符号，仅保留可见链接文本；缺失页交给 missingPlugin 标红。
function autoRenderWikiLink(view, pos) {
  const { state } = view
  const $pos = state.doc.resolve(pos)
  const textBefore = $pos.parent.textBetween(0, $pos.parentOffset, undefined, '￼')
  const m = /\[\[([^\[\]\n]+?)(?:\|([^\[\]\n]+?))?\]\]$/.exec(textBefore)
  if (!m) return false
  const target = m[1].trim()
  if (!target) return false
  let page = target, anchor = ''
  const h = target.indexOf('#')
  if (h >= 0) { page = target.slice(0, h).trim(); anchor = target.slice(h + 1).trim() }
  const alias = m[2] ? m[2].trim() : null
  const display = alias || page
  const markType = state.schema.marks.wikilink
  if (!markType) return false
  const full = m[0].length
  const start = pos - full
  const end = pos
  const tr = state.tr
  tr.delete(start, end)
  tr.insertText(display, start)
  const newEnd = start + display.length
  tr.addMark(start, newEnd, markType.create({ page: page, anchor: anchor || null, alias: alias || null }))
  tr.setSelection(TextSelection.create(tr.doc, newEnd))
  view.dispatch(tr.scrollIntoView())
  return true
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
      const label = (it && typeof it === 'object') ? it.label : String(it)
      html += '<div class="wiki-ac-item wiki-ac-' + (it && it.kind) + (i === this.index ? ' active' : '') + '" data-idx="' + i + '">' + escapeHtml(label) + '</div>'
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
    const it = s.items[i]
    const value = (it && typeof it === 'object') ? it.value : String(it)
    applyWikiLink(this.view, value, s.from, s.to)
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
      const q = (query || '').toLowerCase()
      // 候选：先列页面（来自宿主下发的 __wikiPages），再列当前页的标题（__currentHeadings），
      // 用「#」前缀区分，让用户能直接选段落锚点（点击后插入 [[#Heading]] → 同页跳转锚点）。
      const pages = (window.__wikiPages || [])
        .filter(p => p.toLowerCase().includes(q))
        .slice(0, 6)
        .map(name => ({ kind: 'page', label: name, value: name }))
      const heads = (window.__currentHeadings || [])
        .filter(h => h.toLowerCase().includes(q))
        .slice(0, 4)
        .map(label => ({ kind: 'heading', label: '# ' + label, value: '#' + label }))
      const items = pages.concat(heads)
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
// Markdown common syntax auto-pair for symbols TipTap does NOT auto-pair natively:
//   [ / [[ / ]]  (wikilink & link brackets), ( ) { } " '  (grouping/quotes).
// Note: * ~ ` are intentionally NOT handled here — TipTap StarterKit's native input
// rules already convert **bold** / *italic* / ~~strike~~ / `code` correctly; a custom
// re-pair previously scrambled emphasis text (typing **bold** produced **bold***).
const pairMap = { '[': ']', '(': ')', '{': '}', '"': '"', "'": "'" }
const autoPairKey = new PluginKey('autoPair')
const autoPairPlugin = new Plugin({
  key: autoPairKey,
  props: {
    // 输入成对的左符号时，自动补上右符号并把光标置于中间
    handleTextInput(view, from, to, text) {
      if (!view.editable) return false
      const { state } = view
      if (from !== to) return false  // 有选区时不自动配对，交给默认行为
      // 防止 to+1 / to+2 越界（在文档末尾输入时 textBetween 会抛错）
      const size = state.doc.content.size
      const tb = (a, b) => state.doc.textBetween(a, Math.min(b, size), undefined, '￼')
      const after = tb(to, to + 2)
      const after1 = tb(to, to + 1)
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
          autoRenderWikiLink(view, view.state.selection.to)
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
          autoRenderWikiLink(view, view.state.selection.to)
          return true
        }
        return false
      }
      // 5) * ~ ` 已不再由本插件处理：这些符号由 TipTap StarterKit 的原生 input rule
      //    正确转换（**bold** / *italic* / ~~strike~~ / `code`）。之前在自定义插件里
      //    重新配对它们，会导致输入 **bold** 时多插入一个 **，表现为"加粗识别错乱"。
      //    （占位分支已删除，避免误加；如需扩展请只在原生未覆盖的符号上扩展 pairMap。）
      // 6) 其余成对符号（" ' ( { ）——TipTap 不自动配对，由本插件处理
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
          const after = state.doc.textBetween(sel.to, Math.min(sel.to + 1, state.doc.content.size), undefined, '￼')
          if (after === event.key) {
            const tr = state.tr.setSelection(TextSelection.create(state.doc, sel.to + 1))
            view.dispatch(tr)
            // 输入 ] 跳过自动配对符后，若恰好完成 [[name]]，则自动渲染为 wikilink
            // （真实输入场景下 ] 由 keydown 消费，handleTextInput 不会再触发，故此处也要处理）
            if (event.key === ']') autoRenderWikiLink(view, view.state.selection.to)
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
let currentEditable = true

// 构建版本标记（部署校验用：rsync 前断言打包产物含此字符串，防止误取陈旧 DerivedData 副本）
// 用 window 全局赋值（而非 const），避免 esbuild tree-shaking 把未引用的标记抖掉。
window.MM_EDITOR_BUILD = '2.2.70'

function buildEditor(editable) {
  if (editor) { editor.destroy(); editor = null }
  editor = new Editor({
    element: document.getElementById('editor'),
    extensions: [
      // 启用标准 Markdown 链接 [text](url)（关闭点击跳转/自动链接，编辑体验更可控）
      StarterKit.configure({ link: { openOnClick: false, autolink: false, linkOnPaste: false } }),
      Placeholder.configure({ placeholder: '输入正文，或输入 [[ 关联其他页面…' }),
      WikiLink,
      ListBackspace,
      Table.configure({ resizable: true }),
      TableRow,
      TableHeader,
      TableCell,
      TaskList,
      TaskItem.configure({ nested: true }),
      BubbleMenu.configure({
        element: getBubbleMenuEl(),
        shouldShow: ({ editor, from, to }) => from !== to && !editor.isActive('wikilink')
      }),
      Extension.create({ name: 'missingPluginExt', addProseMirrorPlugins() { return [missingPlugin] } }),
      Extension.create({ name: 'autocompletePluginExt', addProseMirrorPlugins() { return [autocompletePlugin] } }),
      Extension.create({ name: 'autoPairPluginExt', addProseMirrorPlugins() { return [autoPairPlugin] } }),
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
      // v2.2.65：用户编辑正文 → 经 editorBridge 推送 {type:'dirty'} 供宿主切页自动保存判定；
      // 程序化加载（loadMarkdown 的 setContent）期间置 __suppressUpdate 跳过，避免误标脏。
      if (window.__suppressUpdate) return
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
        window.webkit.messageHandlers.editorBridge.postMessage({ type: 'dirty' })
      }
    }
  })
  wireEditorDom()
  wireFormatToolbar()
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

// v2.2.70：frontmatter 双向转换（磁盘 ---...--- ⇄ 编辑器内原生 ```yaml 代码块）
// 以及由宿主注入的「双链关系」派生段（## 反向链接 / ## 本页引用的页面）保存前剥离，不落盘。

// 剥离由宿主注入的派生段：## 反向链接 / ## 本页引用的页面（命中即跳到下一个标题或文末）
function stripRefsSections(md) {
  if (typeof md !== 'string') return md || ''
  const lines = md.split(/\r?\n/)
  const out = []
  let skipping = false
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(#{1,6})\s+(.*)$/)
    if (m) {
      const title = m[2].trim()
      if (title === '反向链接' || title === '本页引用的页面') { skipping = true; continue }
      skipping = false
    }
    if (!skipping) out.push(lines[i])
  }
  return out.join('\n')
}

// 磁盘 → 编辑器：顶部 ---...--- frontmatter 包成 ```yaml 代码块（单真相源 = .md，编辑代码块即编辑 frontmatter）
function frontmatterDashedToFenced(md) {
  if (typeof md !== 'string') return md || ''
  const s = md.replace(/\r\n/g, '\n')
  const fm = s.match(/^---\n([\s\S]*?)\n---\n?/)
  if (fm) {
    const rest = s.slice(fm[0].length)
    return '```yaml\n' + fm[1] + '\n```\n\n' + rest
  }
  return s
}

// 编辑器 → 磁盘：顶部 ```yaml 代码块还原为 ---...---；并剥离双链派生段（不落盘）
function frontmatterFencedToDashed(body) {
  let s = (body || '').replace(/\r\n/g, '\n')
  s = stripRefsSections(s)
  const fence = s.match(/^```yaml\n([\s\S]*?)\n```\n?/)
  if (fence) {
    const rest = s.slice(fence[0].length)
    return '---\n' + fence[1] + '\n---\n\n' + rest
  }
  return s
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
      // 编辑时用 ⌘/Ctrl+Click 跳转；普通点击保留光标定位，符合 Obsidian 习惯。
      if (editor && editor.isEditable && !e.metaKey && !e.ctrlKey) return
      e.preventDefault()
      const name = el.getAttribute('data-page')
      const anchor = el.getAttribute('data-anchor') || ''
      if (name && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
        window.webkit.messageHandlers.editorBridge.postMessage({ type: 'wikilink', name: name, anchor: anchor })
      }
    }
  })
  // v2.2.70：属性/双链均为编辑器内原生 markdown（顶部 ```yaml 代码块 + 正文 ## 反向链接 段），
  // 不再有 #fmBanner / #fmPageRefsContainer 注入式 DOM；双链点击统一由编辑器正文委托处理（见上）。
}

// 固定格式栏：补齐 Typora 常用入口，避免只有选中文字时才出现工具。
function insertWikiTrigger() {
  if (!editor || !editor.isEditable) return
  const { from, to } = editor.state.selection
  const tr = editor.state.tr.insertText('[[]]', from, to)
  tr.setSelection(TextSelection.create(tr.doc, from + 2))
  editor.view.dispatch(tr.scrollIntoView())
}

function wireFormatToolbar() {
  const bar = document.getElementById('formatToolbar')
  if (!bar || bar.dataset.wired) return
  bar.dataset.wired = '1'
  bar.addEventListener('mousedown', event => {
    const button = event.target.closest && event.target.closest('button[data-cmd]')
    if (!button || !editor || !editor.isEditable) return
    event.preventDefault()
    const cmd = button.getAttribute('data-cmd')
    const actions = {
      undo: () => editor.chain().focus().undo().run(),
      redo: () => editor.chain().focus().redo().run(),
      bold: () => editor.chain().focus().toggleBold().run(),
      italic: () => editor.chain().focus().toggleItalic().run(),
      strike: () => editor.chain().focus().toggleStrike().run(),
      code: () => editor.chain().focus().toggleCode().run(),
      h1: () => editor.chain().focus().toggleHeading({ level: 1 }).run(),
      h2: () => editor.chain().focus().toggleHeading({ level: 2 }).run(),
      h3: () => editor.chain().focus().toggleHeading({ level: 3 }).run(),
      bullet: () => editor.chain().focus().toggleBulletList().run(),
      ordered: () => editor.chain().focus().toggleOrderedList().run(),
      task: () => editor.chain().focus().toggleTaskList().run(),
      quote: () => editor.chain().focus().toggleBlockquote().run(),
      wiki: insertWikiTrigger
    }
    if (actions[cmd]) actions[cmd]()
  })
}

// ————————————————————————————————————————————————————————————————
//  公开 API（供 Swift 的 WKWebView 调用）
// ————————————————————————————————————————————————————————————————
window.MMEditor = {
  init() {
    buildEditor(true)
  },
  // 暴露底层 TipTap Editor 实例（供宿主高级集成 / 自动化测试驱动 handleTextInput 等）
  getEditor() {
    return editor
  },
  loadMarkdown(mdText, editable, mode, autoLink, pageName) {
    // 记录当前页名（宿主下发），供 [[#Heading]] 同页锚点渲染时兜底 data-page，
    // 以及自动补全选中 #Heading 候选时拼出 [[Page#Heading]]。
    window.__currentPageName = (typeof pageName === 'string' && pageName.trim()) ? pageName.trim() : ''
    currentEditable = editable !== false
    // 自动双链：加载单人纪要时，把正文里出现的已知 Wiki 页名裸词包裹成 [[名称]]（点击即跳 Wiki）
    let md = mdText || ''
    if (autoLink && window.__autoLinkNames && window.__autoLinkNames.length) {
      md = autoLinkWiki(md, window.__autoLinkNames)
    }
    // v2.2.70：顶部 YAML 属性（磁盘 --- frontmatter）转成编辑器内原生 ```yaml 代码块——
    // 单一真相源 = .md，编辑代码块即编辑 frontmatter，不再有注入式 banner DOM。
    const editorMd = frontmatterDashedToFenced(md)
    const html = md.render(editorMd)
    if (!editor) buildEditor(editable !== false)
    // v2.2.65：setContent 会触发 onUpdate；加载期间置 __suppressUpdate 跳过 dirty 推送，
    // 避免把「载入新页」误判为「用户编辑」（切页自动保存依赖 isDirty 准确性）。
    window.__suppressUpdate = true
    editor.commands.setContent(html, false)
    editor.setEditable(editable !== false)
    window.__suppressUpdate = false
    // 抓取当前页所有 h1-h6 标题，供 [[]] 自动补齐建议同时列出「页面 + 段落」候选
    try {
      const heads = []
      const hs = editor.view.dom.querySelectorAll('h1,h2,h3,h4,h5,h6')
      hs.forEach(h => {
        const t = (h.textContent || '').trim()
        if (t) heads.push(t)
      })
      // 去重保序，最多 16 个
      window.__currentHeadings = Array.from(new Set(heads)).slice(0, 16)
    } catch (e) { window.__currentHeadings = [] }
    // 刷新缺失页装饰
    editor.view.dispatch(editor.state.tr.setMeta(missingKey, { recompute: true }))
  },
  requestSave() {
    if (!editor) return
    const html = editor.getHTML()
    let body = turndownService.turndown(html)
    body = body.replace(/\n{3,}/g, '\n\n').replace(/[ \t]+$/gm, '')
    // v2.2.70：编辑器内首个 ```yaml 属性块 → 磁盘 --- frontmatter（保持 Obsidian / pipeline 兼容）
    const out = frontmatterFencedToDashed(body.trimEnd())
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
      window.webkit.messageHandlers.editorBridge.postMessage({ type: 'save', markdown: out })
    }
  },
  /// 取出"当前页面的完整 Markdown（含 frontmatter）"，用于宿主侧属性编辑面板预填。
  requestCurrentMarkdown() {
    if (!editor) return ''
    const html = editor.getHTML()
    let body = turndownService.turndown(html)
    body = body.replace(/\n{3,}/g, '\n\n').replace(/[ \t]+$/gm, '')
    return frontmatterFencedToDashed(body.trimEnd())
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
  showPreview(name, html) { window.MMEditor_showPreview(name, html) },
  // 双链点击后跳转到 Wiki 页并滚动到锚点标题（Obsidian 式 [[Page#Heading]]）
  scrollToAnchor(anchor) {
    const a = (anchor || '').trim()
    if (!a || !editor) return
    const heads = editor.view.dom.querySelectorAll('h1,h2,h3,h4,h5,h6')
    let target = null
    heads.forEach(h => { if (!target && h.textContent.trim().toLowerCase() === a.toLowerCase()) target = h })
    if (!target) {
      try { target = editor.view.dom.querySelector('#' + CSS.escape(a)) } catch (e) {}
    }
    if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }
}

// ⌘S 保存
document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
    e.preventDefault()
    window.MMEditor.requestSave()
  }
  if ((e.metaKey || e.ctrlKey) && !e.shiftKey && (e.key === 'k' || e.key === 'K')) {
    e.preventDefault()
    insertWikiTrigger()
  }
})

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
