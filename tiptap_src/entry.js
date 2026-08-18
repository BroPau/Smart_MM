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
function parseFrontmatter(lines) {
  const fm = {}
  let i = 0
  while (i < lines.length) {
    const s = lines[i]
    const m = s.match(/^([^\s:]+):\s*(.*)$/)
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
// ————————————————————————————————————————————————————————————————
//  双兼容 key 归一化（v2.2.32）：用户 wiki page frontmatter 改为中文 key；
//  pipeline 写入路径仍可能写出 PascalCase，因此展示层统一折叠到内部 canonical key。
//  仅做只读展示，不会改写已保存的 frontmatter 文件（保存路径走 serializeFrontmatter 用原 key 名）。
// ————————————————————————————————————————————————————————————————
const KEY_ALIASES = {
  类型: 'type', Type: 'type', type: 'type',
  规范名: 'canonical_name', CanonicalName: 'canonical_name', canonical_name: 'canonical_name', canonicalname: 'canonical_name',
  别名: 'aliases', Aliases: 'aliases', aliases: 'aliases',
  标签: 'tags', Tags: 'tags', tags: 'tags',
  更新时间: 'updated', Updated: 'updated', updated: 'updated',
  反向链接: 'backlinks', Backlinks: 'backlinks', backlinks: 'backlinks',
  公司: 'company', Company: 'company', company: 'company',
  职位: 'title', Title: 'title', title: 'title'
}
function fmCanonical(k) { return KEY_ALIASES[k] || k }
function fmNormalize(fm) {
  const out = {}
  const seen = new Set()
  for (const k of Object.keys(fm)) {
    const c = fmCanonical(k)
    if (!seen.has(c)) { out[c] = fm[k]; seen.add(c) }
  }
  return out
}
// ————————————————————————————————————————————————————————————————
//  frontmatter 属性 banner（数据驱动：读 page 实际 frontmatter 键 → 全部显示 → 仅做键名→中文翻译）
// ————————————————————————————————————————————————————————————————
// 已知键的展示顺序；page 中出现的未知键保持原顺序追加到末尾（backlinks 固定最后）
// 顺序约定（用户要求，v2.2.29）：
//   - 最上方固定为「类型」(type)
//   - 公司类型 / 所属行业 / 公司简介 放在 aliases 与 tags 之间
//   - 其余已知字段维持原有相对次序
const FM_ORDER = [
  'type', 'canonical_name', '中文名', 'company', 'title', '职能范围',
  '品牌', '具体型号', '类别', '功能简述', '状态', '替代料',
  'aliases', '公司类型', '所属行业', '公司简介', 'tags',
  'updated', 'backlinks'
]
// 内部标记键，不展示（如 MOC 首页的 wiki_首页 标志）
const FM_SKIP = { wiki_首页: 1 }
// 英文键 → 中文标签（统一界面语言，避免中英混合）。中文键原样透传。
const FM_LABEL_CN = {
  type: '类型',
  canonical_name: '规范名',
  company: '公司',
  title: '职位',
  aliases: '别名',
  tags: '标签',
  updated: '更新时间',
  backlinks: '反向链接'
}
function fmLabel(k) { return FM_LABEL_CN[k] || k }

// 字段类型推断（决定渲染控件与图标）。page 有什么字段就显示什么字段，不猜测、不丢弃。
function fmFieldType(key, value) {
  if (key === 'type') return 'select'
  if (key === 'backlinks') return 'readonly'
  if (key === 'aliases' || key === 'tags') return 'list'
  const kl = String(key).toLowerCase()
  if (kl === 'updated' || kl === 'created' || kl === 'date' || kl.endsWith('_date')) return 'date'
  if (key === '公司简介' || key === '职能范围' || key === '功能简述' || key === '概要' || key === 'summary' || key === 'description') return 'longtext'
  return 'text'
}
// Obsidian 风格字段图标（左侧小图标）
function fmFieldIcon(type, key) {
  if (type === 'list' && key === 'tags') return '🏷'   // 标签
  if (type === 'list') return '↗'                       // 别名（列表）
  if (type === 'date') return '📅'                      // 日期
  if (type === 'select') return '≡'                     // 类型
  if (type === 'readonly') return '🔗'                  // 反向链接
  return '≡'                                             // 文本 / 长文本
}

// 按 FM_ORDER 排序已知键，未知键按出现顺序追加（剔除 FM_SKIP）
function fmOrderedKeys(fm) {
  const known = FM_ORDER.filter(k => Object.prototype.hasOwnProperty.call(fm, k))
  const unknown = Object.keys(fm).filter(k => !FM_ORDER.includes(k) && !FM_SKIP[k])
  return known.concat(unknown)
}
// 值 → 展示字符串（数组用「、」连接；剥离外层 [] / () / 引号）
function fmDisplay(v) {
  if (v === undefined || v === null) return ''
  let s = Array.isArray(v) ? v.map(x => String(x).trim()).filter(Boolean).join('、') : String(v).trim()
  s = s.replace(/^[\[\(](.*)[\]\)]$/, '$1').replace(/^["“”']|["“”']$/g, '')
  return s
}
// 列表字段 → 非空白项数组（兼容真实数组与 '[]' / '[a, b]' 字符串写法）
function fmListItems(v) {
  if (Array.isArray(v)) return v.map(x => String(x).trim()).filter(Boolean)
  if (v == null) return []
  let s = String(v).trim().replace(/^[\[\(](.*)[\]\)]$/, '$1').trim()
  if (!s) return []
  return s.split(/[,，、]/).map(x => x.trim()).filter(Boolean)
}
// 反向链接 → 只读 pill HTML（兼容数组 / 字符串 / [[..|..]] 语法）；无内容返回 ''
function renderBacklinks(bl) {
  if (!bl) return ''
  let items = Array.isArray(bl) ? bl.slice() : String(bl).split(/[,，、]/)
  items = items.map(s => String(s).trim()).filter(Boolean)
  if (!items.length) return ''
  items = items.map(s => s.replace(/^\[\[/, '').replace(/\]\]$/, '').replace(/\|/g, ' · '))
  return '<span class="fm-backlinks">' +
    items.map(s => '<span class="fm-backlink-pill">' + escapeHtml(s) + '</span>').join(' ') +
    '</span>'
}

// 只读 banner（Obsidian 风格）：遍历 page 实际键全部显示；列表→chip、日期→日历、backlinks→只读
function renderFrontmatterBanner(fm) {
  if (!fm || Object.keys(fm).length === 0) return ''
  const rows = []
  fmOrderedKeys(fm).forEach(k => {
    if (FM_SKIP[k]) return
    const t = fmFieldType(k, fm[k])
    const icon = fmFieldIcon(t, k)
    const label = fmLabel(k)
    if (t === 'list') {
      const items = fmListItems(fm[k])
      if (!items.length) return
      const chips = '<span class="fm-chips readonly">' + items.map(it => '<span class="fm-chip">' + escapeHtml(it) + '</span>').join('') + '</span>'
      rows.push(fmRowHtml(icon, label, chips))
    } else if (t === 'readonly') {
      const blHtml = renderBacklinks(fm[k])
      if (!blHtml) return
      rows.push(fmRowHtml(icon, label, '<div class="fm-readonly">' + blHtml + '</div>'))
    } else if (t === 'date') {
      const dv = (fm[k] || '').toString().trim()
      if (!dv) return
      rows.push(fmRowHtml(icon, label, '<span class="fm-date-val">' + escapeHtml(dv) + '</span>'))
    } else if (t === 'longtext') {
      const dv = (fm[k] == null ? '' : String(fm[k])).trim()
      // 长文本即使为空也保留一行「（空）」占位，确保该字段始终在 banner 中可见、可被定位
      const inner = dv
        ? '<div class="fm-longtext-val">' + escapeHtml(dv) + '</div>'
        : '<div class="fm-longtext-val fm-empty">（空）</div>'
      rows.push(fmRowHtml(icon, label, inner, { long: true }))
    } else {
      const dv = fmDisplay(fm[k])
      if (!dv) return
      rows.push(fmRowHtml(icon, label, '<span class="fm-scalar-val">' + escapeHtml(dv) + '</span>'))
    }
  })
  if (rows.length === 0) return ''
  return '<div class="fm-grid">' + rows.join('') + '</div>'
}
// 共享：单行 [图标 + 标签] + [值]；long=true 时整行跨列（label 一行 + value 一行）
function fmRowHtml(icon, label, valueHtml, opts) {
  const cls = (opts && opts.long) ? 'fm-row fm-row-long' : 'fm-row'
  return '<div class="' + cls + '"><div class="fm-row-label"><span class="fm-icon">' + icon + '</span><span class="fm-key">' + escapeHtml(label) + '</span></div>' +
    '<div class="fm-row-value">' + valueHtml + '</div></div>'
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
    if (page.length === 0) page = anchor
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
  let tr = state.tr
  tr.delete(from, to)
  const text = page
  tr.insertText(text, from)
  const end = from + text.length
  tr.addMark(from, end, markType.create({ page: page, alias: null }))
  tr.setSelection(TextSelection.create(tr.doc, end))
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
      const anchor = el.getAttribute('data-anchor') || ''
      if (name && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
        window.webkit.messageHandlers.editorBridge.postMessage({ type: 'wikilink', name: name, anchor: anchor })
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
  // 暴露底层 TipTap Editor 实例（供宿主高级集成 / 自动化测试驱动 handleTextInput 等）
  getEditor() {
    return editor
  },
  loadMarkdown(mdText, editable, mode, autoLink) {
    const sp = splitFrontmatter(mdText || '')
    pendingFrontmatter = sp.fmRaw
    currentFM = sp.fmRaw ? fmNormalize(parseFrontmatter(sp.fmRaw.split('\n').slice(1, -1))) : {}
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

// 防抖保存（标量 / chip / 新增属性 改动后统一调用）
let _bannerSaveTimer = null
function scheduleSave() {
  if (_bannerSaveTimer) clearTimeout(_bannerSaveTimer)
  _bannerSaveTimer = setTimeout(() => {
    if (window.MMEditor && window.MMEditor.requestSave) window.MMEditor.requestSave()
  }, 400)
}
// 动态创建的 chip × 按钮：删除列表项
function onChipRemove(e) {
  const btn = e.currentTarget
  const k = btn.getAttribute('data-remove-chip')
  const v = btn.getAttribute('data-val')
  if (Array.isArray(currentFM[k])) {
    currentFM[k] = currentFM[k].filter(x => x !== v)
    pendingFrontmatter = serializeFrontmatter(currentFM)
    const chip = btn.closest('.fm-chip')
    if (chip && chip.parentNode) chip.parentNode.removeChild(chip)
    scheduleSave()
  }
}

// 给表单每个字段绑定事件：标量/下拉/日期/长文本实时写回；chip 增删；添加属性。
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
      scheduleSave()
    }
    el.addEventListener('input', onEdit)
    el.addEventListener('change', onEdit)
    // 「类型」select 改变后整段重渲染 banner（数据驱动：字段来自 page 实际 frontmatter，不再按类型显隐）
    if (el.tagName === 'SELECT' && el.getAttribute('data-fm') === 'type') {
      el.addEventListener('change', () => {
        setTimeout(renderBanner, 0)
        // 同步 tags：剔除旧类型 token，追加新类型
        const newType = (currentFM['type'] || '').toString().trim()
        const TYPE_TOKENS = ['Person', 'Company', 'Chip', 'Project', 'Topic', 'Method', 'person', 'company', 'chip', 'project', 'product', 'topic', 'method']
        if (Array.isArray(currentFM['tags'])) {
          currentFM['tags'] = currentFM['tags'].filter(t => t && t !== 'wiki' && !TYPE_TOKENS.includes(t))
          if (newType && !currentFM['tags'].includes(newType)) currentFM['tags'].push(newType)
        }
        pendingFrontmatter = serializeFrontmatter(currentFM)
      })
    }
  })
  root.querySelectorAll('[data-addtype]').forEach(btn => {
    btn.addEventListener('click', () => {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
        window.webkit.messageHandlers.editorBridge.postMessage({ type: 'addCustomType' })
      }
    })
  })
  // 列表字段：chip × 删除
  root.querySelectorAll('[data-remove-chip]').forEach(btn => {
    btn.addEventListener('click', onChipRemove)
  })
  // 列表字段：输入回车 / 失焦 新增 chip
  root.querySelectorAll('[data-add-chip]').forEach(inp => {
    const addItem = () => {
      const k = inp.getAttribute('data-add-chip')
      const v = inp.value.trim()
      if (!v) return
      if (!Array.isArray(currentFM[k])) currentFM[k] = []
      if (!currentFM[k].includes(v)) {
        currentFM[k].push(v)
        const chip = document.createElement('span')
        chip.className = 'fm-chip'
        chip.setAttribute('data-val', v)
        chip.innerHTML = '<span>' + escapeHtml(v) + '</span><button type="button" class="fm-chip-x" data-remove-chip="' + escapeAttr(k) + '" data-val="' + escapeAttr(v) + '">×</button>'
        inp.parentNode.insertBefore(chip, inp)
        chip.querySelector('.fm-chip-x').addEventListener('click', onChipRemove)
        pendingFrontmatter = serializeFrontmatter(currentFM)
        scheduleSave()
      }
      inp.value = ''
    }
    inp.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); addItem() } })
    inp.addEventListener('blur', addItem)
  })
  // 添加笔记属性：一行「属性名 + 值」，回车提交为新 frontmatter 键
  root.querySelectorAll('[data-add-prop]').forEach(btn => {
    btn.addEventListener('click', () => {
      const form = btn.closest('.fm-grid.edit') || root
      const row = document.createElement('div')
      row.className = 'fm-row fm-row-new'
      row.innerHTML = '<div class="fm-row-label"><span class="fm-icon">≡</span><input type="text" class="fm-newkey" placeholder="属性名"></div>' +
        '<div class="fm-row-value"><input type="text" class="fm-newval" placeholder="值"></div>'
      form.insertBefore(row, btn.closest('.fm-add-row'))
      const keyInput = row.querySelector('.fm-newkey')
      const valInput = row.querySelector('.fm-newval')
      keyInput.focus()
      const commit = () => {
        const nk = keyInput.value.trim()
        const nv = valInput.value.trim()
        if (nk) {
          currentFM[nk] = nv
          pendingFrontmatter = serializeFrontmatter(currentFM)
          renderBanner()
          scheduleSave()
        } else if (row.parentNode) {
          row.parentNode.removeChild(row)
        }
      }
      valInput.addEventListener('blur', commit)
      valInput.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); commit() } })
      keyInput.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); valInput.focus() } })
    })
  })
}

// 可编辑属性表单（Obsidian 风格）：遍历 page 实际 frontmatter 的全部键全部可编辑显示；
// 列表→chip、日期→date、类型→select、长文本→textarea；page 有什么字段就显示什么字段。
function renderBannerEditForm(fm) {
  if (!fm) fm = {}
  const TYPES = ['Person', 'Company', 'Chip', 'Project', 'Topic', 'Method']
  const rawType = (fm['type'] || '').toString().trim()

  let html = '<div class="fm-grid edit">'
  fmOrderedKeys(fm).forEach(k => {
    if (FM_SKIP[k]) return
    const t = fmFieldType(k, fm[k])
    const icon = fmFieldIcon(t, k)
    const label = fmLabel(k)
    let valHtml = ''
    if (t === 'select') {
      // 把 legacy 小写 / product 旧值也列出来，避免下拉里没有当前值导致选不中
      const base = TYPES.slice()
      if (rawType && !base.includes(rawType)) base.push(rawType)
      const opts = base.concat(CUSTOM_TYPES.filter(x => !base.includes(x)))
      valHtml = '<div class="fm-type-row"><select data-fm="type" data-kind="scalar" class="fm-select">' +
        opts.map(o => '<option value="' + escapeAttr(o) + '"' + (rawType === o ? ' selected' : '') + '>' + escapeHtml(o) + '</option>').join('') + '</select>' +
        '<button type="button" data-addtype="1" class="fm-addtype" title="新增自定义类型（共享到所有 WiKi 页）">＋</button></div>'
    } else if (t === 'list') {
      const items = fmListItems(fm[k])
      valHtml = '<div class="fm-chips" data-list="' + escapeAttr(k) + '">' +
        items.map(it => '<span class="fm-chip" data-val="' + escapeAttr(it) + '"><span>' + escapeHtml(it) + '</span><button type="button" class="fm-chip-x" data-remove-chip="' + escapeAttr(k) + '" data-val="' + escapeAttr(it) + '">×</button></span>').join('') +
        '<input type="text" class="fm-chip-add" data-add-chip="' + escapeAttr(k) + '" placeholder="添加…"></div>'
    } else if (t === 'date') {
      const dv = (fm[k] || '').toString().trim()
      valHtml = '<input type="date" data-fm="' + escapeAttr(k) + '" data-kind="scalar" value="' + escapeAttr(dv) + '" class="fm-date">'
    } else if (t === 'readonly') {
      const blHtml = renderBacklinks(fm[k])
      valHtml = '<div class="fm-readonly">' + (blHtml || '<span class="fm-empty">（空）</span>') + '</div>'
    } else if (t === 'longtext') {
      // 长文本：textarea 跨整行（label 一行 + value 一行），不挤压到右侧窄列
      valHtml = '<textarea data-fm="' + escapeAttr(k) + '" data-kind="scalar" class="fm-textarea" placeholder="（空）" rows="3">' + escapeHtml(fm[k] == null ? '' : String(fm[k])) + '</textarea>'
      html += fmRowHtml(icon, label, valHtml, { long: true })
      return  // 跳到下一次 forEach（已写入）
    } else {
      valHtml = '<input type="text" data-fm="' + escapeAttr(k) + '" data-kind="scalar" value="' + escapeAttr(fm[k] == null ? '' : String(fm[k])) + '" class="fm-text">'
    }
    html += fmRowHtml(icon, label, valHtml)
  })
  // 添加笔记属性：点击插入一行「属性名 + 值」输入，回车即提交为新的 frontmatter 键
  html += '<div class="fm-add-row"><button type="button" class="fm-add-prop" data-add-prop="1">+ 添加笔记属性</button></div>'
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
