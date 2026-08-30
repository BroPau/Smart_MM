// ============================================================================
//  Meetinsight — Milkdown 编辑器核心（离线打包，无外部网络依赖）
//  真·WYSIWYG（Typora 风格 markdown-native）：所见即 markdown 渲染结果，
//  不再保留 Markdown 源码符号（与用户「零符号实时渲染」诉求一致）。
//  双链：[[Page]] / [[Page|alias]] 渲染为可点击 pill（link mark，href=wikilink:ENCODED）；
//        - 缺失页 → 红色虚线下划线（一键创建）
//        - 输入 [[ 自动弹出候选（⌘/↑↓/↵ 选择）
//        - 悬浮预览气泡
//  与宿主通过 window.webkit.messageHandlers.editorBridge 通信（消息类型与旧版 TipTap 完全一致）。
//  依赖：@milkdown/core + preset-commonmark + preset-gfm + utils（markdown 往返由 Milkdown transformer 完成）。
// ============================================================================

import { Editor, rootCtx, defaultValueCtx, editorViewCtx, parserCtx, remarkStringifyOptionsCtx } from '@milkdown/core'
import { commonmark } from '@milkdown/preset-commonmark'
import { gfm } from '@milkdown/preset-gfm'
import { getMarkdown, replaceAll, $prose, insert } from '@milkdown/utils'
import { Plugin, PluginKey, TextSelection } from '@milkdown/prose/state'
import { Decoration, DecorationSet } from '@milkdown/prose/view'

const bridge = (msg) => {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
    window.webkit.messageHandlers.editorBridge.postMessage(msg)
  }
}

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
const FM_ORDER = [
  'type', 'canonical_name', 'aliases',
  '中文名', 'company', 'title', '职能范围',
  '公司类型', '所属行业', '公司简介',
  '品牌', '具体型号', '类别', '功能简述', '状态', '替代料',
  'tags', 'updated'
]
const FM_SKIP = { wiki_首页: 1, backlinks: 1 }
const FM_LABEL_CN = {
  type: '类型',
  canonical_name: '规范名',
  company: '公司',
  title: '职位',
  aliases: '别名',
  tags: '标签',
  updated: '更新时间'
}
function fmLabel(k) { return FM_LABEL_CN[k] || k }

function fmFieldType(key, value) {
  if (key === 'type') return 'select'
  if (key === 'aliases' || key === 'tags') return 'list'
  const kl = String(key).toLowerCase()
  if (kl === 'updated' || kl === 'created' || kl === 'date' || kl.endsWith('_date')) return 'date'
  if (key === '公司简介' || key === '职能范围' || key === '功能简述' || key === '概要' || key === 'summary' || key === 'description') return 'longtext'
  return 'text'
}
function fmFieldIcon(type, key) {
  if (type === 'list' && key === 'tags') return '🏷'
  if (type === 'list') return '↗'
  if (type === 'date') return '📅'
  if (type === 'select') return '≡'
  return '≡'
}
function fmOrderedKeys(fm) {
  const known = FM_ORDER.filter(k => Object.prototype.hasOwnProperty.call(fm, k))
  const unknown = Object.keys(fm).filter(k => !FM_ORDER.includes(k) && !FM_SKIP[k])
  return known.concat(unknown)
}
function fmDisplay(v) {
  if (v === undefined || v === null) return ''
  let s = Array.isArray(v) ? v.map(x => String(x).trim()).filter(Boolean).join('、') : String(v).trim()
  s = s.replace(/^[\[\(](.*)[\]\)]$/, '$1').replace(/^["“”']|["“”']$/g, '')
  return s
}
function fmListItems(v) {
  if (Array.isArray(v)) return v.map(x => String(x).trim()).filter(Boolean)
  if (v == null) return []
  let s = String(v).trim().replace(/^[\[\(](.*)[\]\)]$/, '$1').trim()
  if (!s) return []
  return s.split(/[,，、]/).map(x => x.trim()).filter(Boolean)
}
// 把标量 / 长文本值里的 [[Page]] / [[Page|alias]] / [[Page#anchor]] 渲染成可点击双向链接（只读展示用）
function renderWikiText(s) {
  if (!s) return ''
  const esc = escapeHtml(s)
  return esc.replace(/\[\[([^\]|]+?)(?:\|([^\]]+?))?\]\]/g, (m, p, a) => {
    const target = (p || '').trim()
    const alias = (a || '').trim()
    if (!target) return m
    let page = target, anchor = ''
    const h = target.indexOf('#')
    if (h >= 0) {
      page = target.slice(0, h).trim()
      anchor = target.slice(h + 1).trim()
      if (!page) page = anchor
    }
    if (!page) return m
    const anchorAttr = anchor ? ' data-anchor="' + escapeAttr(anchor) + '"' : ''
    return '<a class="wikilink" data-wikilink data-page="' + escapeAttr(page) + '"' +
      (alias ? ' data-alias="' + escapeAttr(alias) + '"' : '') +
      anchorAttr + '>' + escapeHtml(alias || page) + '</a>'
  })
}
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
    } else if (t === 'date') {
      const dv = (fm[k] || '').toString().trim()
      if (!dv) return
      rows.push(fmRowHtml(icon, label, '<span class="fm-date-val">' + escapeHtml(dv) + '</span>'))
    } else if (t === 'longtext') {
      const dv = (fm[k] == null ? '' : String(fm[k])).trim()
      const inner = dv
        ? '<div class="fm-longtext-val">' + renderWikiText(dv) + '</div>'
        : '<div class="fm-longtext-val fm-empty">（空）</div>'
      rows.push(fmRowHtml(icon, label, inner))
    } else {
      const dv = fmDisplay(fm[k])
      if (!dv) return
      rows.push(fmRowHtml(icon, label, '<span class="fm-scalar-val">' + renderWikiText(dv) + '</span>'))
    }
  })
  if (rows.length === 0) return ''
  return '<div class="fm-grid">' + rows.join('') + '</div>'
}
function fmRowHtml(icon, label, valueHtml, opts) {
  const cls = (opts && opts.long) ? 'fm-row fm-row-long' : 'fm-row'
  return '<div class="' + cls + '"><div class="fm-row-label"><span class="fm-icon">' + icon + '</span><span class="fm-key">' + escapeHtml(label) + '</span></div>' +
    '<div class="fm-row-value">' + valueHtml + '</div></div>'
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
  bridge({ type: 'wikilinkPreview', name: name })
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
//  编辑器实例状态
// ————————————————————————————————————————————————————————————————
let editor = null
let pendingFrontmatter = ''
let currentFM = {}
let currentEditable = true
let pageRefsOut = []
let pageRefsIn = []
let CUSTOM_TYPES = []
let WIKIPAGES = []
let AUTO_LINK_NAMES = []
let wired = false

// ————————————————————————————————————————————————————————————————
//  [[双链]] 处理：wikilink: 链接协议（避免自定义 micromark 扩展）
// ————————————————————————————————————————————————————————————————
const WIKILINK_RE = /\[\[([^\[\]\n]+?)\]\]/g
function preProcessWiki(body) {
  return body.replace(WIKILINK_RE, (_, inner) => {
    const idx = inner.indexOf('|')
    let target, alias
    if (idx >= 0) { target = inner.slice(0, idx); alias = inner.slice(idx + 1) }
    else { target = inner; alias = inner }
    const enc = encodeURIComponent(target)
    return '[' + alias + '](wikilink:' + enc + ')'
  })
}
const LINK_RE = /\[([^\]]*)\]\(wikilink:([^)\s]+)\)/g
function postProcessWiki(md) {
  return md.replace(LINK_RE, (_, alias, enc) => {
    const target = decodeURIComponent(enc)
    if (alias === target) return '[[' + target + ']]'
    return '[[' + target + '|' + alias + ']]'
  })
}

// ————————————————————————————————————————————————————————————————
//  ProseMirror 插件：wikilink 样式 + 缺失页标红（Milkdown 复用同一 ProseMirror）
// ————————————————————————————————————————————————————————————————
const wikiLinkKey = new PluginKey('milkdownWikilink')
function wikiLinkPlugin() {
  return new Plugin({
    key: wikiLinkKey,
    props: {
      decorations(state) {
        const decos = []
        state.doc.descendants((node, pos) => {
          if (!node.isText) return
          const link = node.marks.find(m => m.type.name === 'link')
          if (!link) return
          const href = link.attrs.href || ''
          if (!href.startsWith('wikilink:')) return
          const target = decodeURIComponent(href.slice('wikilink:'.length))
          let page = target, anchor = ''
          const h = target.indexOf('#')
          if (h >= 0) { page = target.slice(0, h).trim(); anchor = target.slice(h + 1).trim() }
          const missing = page && WIKIPAGES.length && !WIKIPAGES.some(p => p.toLowerCase() === page.toLowerCase())
          const cls = 'wikilink' + (missing ? ' wikilink-missing' : '')
          decos.push(Decoration.inline(pos, pos + node.nodeSize, {
            class: cls,
            'data-wikilink': target,
            'data-page': page
          }))
        })
        return DecorationSet.create(state.doc, decos)
      }
    }
  })
}

// 插入 [[Page]] / [[Page|alias]] 完成后的自动渲染（Obsidian 式「输入双方括号即自动渲染」）
function applyWikiLink(view, page, from, to) {
  const { state } = view
  const markType = state.schema.marks.link
  if (!markType) return
  let anchor = null
  let display = page
  if (typeof page === 'string') {
    if (page.charAt(0) === '#') {
      const heading = page.slice(1).trim()
      const cur = (window.__currentPageName || '').trim()
      anchor = heading
      display = heading
      page = cur || heading
    } else {
      const h = page.indexOf('#')
      if (h >= 0) {
        anchor = page.slice(h + 1).trim()
        page = page.slice(0, h).trim()
        if (!anchor) anchor = null
      }
    }
  }
  const enc = encodeURIComponent(page)
  const href = 'wikilink:' + enc
  let tr = state.tr
  tr = tr.delete(from, to)
  const text = display
  tr = tr.insertText(text, from)
  const end = from + text.length
  if (end + 2 <= tr.doc.content.size) {
    const after = tr.doc.textBetween(end, Math.min(end + 2, tr.doc.content.size), undefined, '￼')
    if (after === ']]') tr = tr.delete(end, end + 2)
  }
  tr = tr.addMark(from, end, markType.create({ href }))
  tr = tr.setSelection(TextSelection.create(tr.doc, end))
  view.dispatch(tr)
}
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
  const markType = state.schema.marks.link
  if (!markType) return false
  const full = m[0].length
  const start = pos - full
  const end = pos
  const enc = encodeURIComponent(page)
  const href = 'wikilink:' + enc
  const tr = state.tr
  tr.delete(start, end)
  tr.insertText(display, start)
  const newEnd = start + display.length
  tr.addMark(start, newEnd, markType.create({ href }))
  tr.setSelection(TextSelection.create(tr.doc, newEnd))
  view.dispatch(tr.scrollIntoView())
  return true
}

// 自动补全候选视图
const wikiAcKey = new PluginKey('milkdownWikiAc')
let wikiAcViewRef = null
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
//  自动配对 / 自动补全语法符号
// ————————————————————————————————————————————————————————————————
const pairMap = { '[': ']', '(': ')', '{': '}', '"': '"', "'": "'" }
const autoPairKey = new PluginKey('milkdownAutoPair')
const autoPairPlugin = new Plugin({
  key: autoPairKey,
  props: {
    handleTextInput(view, from, to, text) {
      if (!view.editable) return false
      const { state } = view
      if (from !== to) return false
      const size = state.doc.content.size
      const tb = (a, b) => state.doc.textBetween(a, Math.min(b, size), undefined, '￼')
      const after = tb(to, to + 2)
      const after1 = tb(to, to + 1)
      const before = from > 0 ? state.doc.textBetween(from - 1, from, undefined, '￼') : ''
      if (text === '[[') {
        const tr = state.tr.insertText('[[]]', from)
        tr.setSelection(TextSelection.create(tr.doc, from + 2))
        view.dispatch(tr.scrollIntoView())
        return true
      }
      if (text === ']]') {
        if (after === ']]') {
          const tr = state.tr.setSelection(TextSelection.create(state.doc, to + 2))
          view.dispatch(tr)
          autoRenderWikiLink(view, view.state.selection.to)
          return true
        }
        return false
      }
      if (text === '[') {
        if (after1 === '[') {
          const tr = state.tr.insertText(']]', to)
          tr.setSelection(TextSelection.create(tr.doc, to))
          view.dispatch(tr.scrollIntoView())
          return true
        }
        if (after1 === ']' && before === '[') {
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
      if (text === ']') {
        if (after1 === ']') {
          const tr = state.tr.setSelection(TextSelection.create(state.doc, to + 1))
          view.dispatch(tr)
          autoRenderWikiLink(view, view.state.selection.to)
          return true
        }
        return false
      }
      if (pairMap[text]) {
        const close = pairMap[text]
        const tr = state.tr.insertText(text + close, from)
        tr.setSelection(TextSelection.create(tr.doc, from + 1))
        view.dispatch(tr.scrollIntoView())
        return true
      }
      return false
    },
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
    if (/^\s*(```|~~~)/.test(line)) { inFence = !inFence; out += line + '\n'; continue }
    if (inFence) { out += line + '\n'; continue }
    out += autoLinkLine(line, sorted) + '\n'
  }
  return out
}
function autoLinkLine(line, sorted) {
  const protectedChunks = []
  let s = line
  s = s.replace(/`[^`]*`/g, m => { protectedChunks.push(m); return '\u0000' + (protectedChunks.length - 1) + '\u0000' })
  s = s.replace(/\[[^\]]*\]\([^)]*\)/g, m => { protectedChunks.push(m); return '\u0000' + (protectedChunks.length - 1) + '\u0000' })
  s = s.replace(/\[\[[^\]]*\]\]/g, m => { protectedChunks.push(m); return '\u0000' + (protectedChunks.length - 1) + '\u0000' })
  for (const name of sorted) {
    const esc = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const re = new RegExp(esc, 'g')
    s = s.replace(re, '[[$&]]')
    s = s.replace(/\[\[[^\]]*\]\]/g, m => { protectedChunks.push(m); return '\u0000' + (protectedChunks.length - 1) + '\u0000' })
  }
  s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => protectedChunks[Number(i)])
  return s
}

// ————————————————————————————————————————————————————————————————
//  v2.2.70：[C] frontmatter 直接作为正文 Markdown 表格（disk 仍存 YAML）
//  - 旧 renderBanner / renderBannerEditForm / wireBannerForm 全部下线
//  - 当前 currentFM 与 pendingFrontmatter 仍保留为内存镜像，用于：
//    · Wiki 页打开时把已有 YAML 转成 Markdown 表注入正文
//    · save 时从正文 Markdown 表反解回 YAML
//  - 在编辑器里**直接编辑** Markdown 表即可改属性，Milkdown auto-save
// ————————————————————————————————————————————————————————————————
function renderBanner() { /* v2.2.70：frontmatter 已迁到正文 Markdown 表，banner 渲染下线 */ }

let _bannerSaveTimer = null
function scheduleSave() {
  if (_bannerSaveTimer) clearTimeout(_bannerSaveTimer)
  _bannerSaveTimer = setTimeout(() => {
    if (window.MMEditor && window.MMEditor.requestSave) window.MMEditor.requestSave()
  }, 400)
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

// ————————————————————————————————————————————————————————————————
//  v2.2.70：[A] frontmatter → 编辑器正文内 Markdown 表格（磁盘仍为 YAML）
//  - HTML 注释 <!--FM_TABLE_BEGIN-->...<!--FM_TABLE_END--> 作为块标记
//  - 表头 = YAML 原 key（类型、Type、canonical_name 等）
//  - 列表值（aliases / tags）以「、」在单元格内串接
//  - 加载：currentFM → 注入正文首段；保存：从正文首段反解回 YAML
//  - 此形态让用户能直接在 Milkdown 表格里改属性，跟正文 markdown 完全同构
// ————————————————————————————————————————————————————————————————
function renderFrontmatterMarkdownTable(fm) {
  if (!fm || typeof fm !== 'object') return ''
  const keys = fmOrderedKeys(fm).filter(k => !FM_SKIP[k])
  if (keys.length === 0) return ''
  const headerRow = '| ' + keys.map(k => escMdTable(k)).join(' | ') + ' |'
  const sepRow = '| ' + keys.map(_ => '---').join(' | ') + ' |'
  const valRow = '| ' + keys.map(k => {
    const v = fm[k]
    if (v == null) return ''
    if (Array.isArray(v)) {
      return escMdTable(v.map(x => String(x).trim()).filter(Boolean).join('、'))
    }
    return escMdTable(String(v).replace(/\r?\n/g, ' ').trim())
  }).join(' | ') + ' |'
  return '<!--FM_TABLE_BEGIN-->\n\n' + headerRow + '\n' + sepRow + '\n' + valRow + '\n\n<!--FM_TABLE_END-->'
}
function escMdTable(s) {
  if (s == null) return ''
  return String(s).replace(/\|/g, '\\|').replace(/\n/g, ' ')
}
// 从 markdown 正文里提取 frontmatter table 块 + refs table 块 + 用户正文
// 返回 { fmRaw(body YAML), body(用户正文), refsRaw(refs markdown 段) }
function splitEditorBlocks(body) {
  let fmRaw = ''
  let refsRaw = ''
  const fmMatch = body.match(/<!--FM_TABLE_BEGIN-->([\s\S]*?)<!--FM_TABLE_END-->/)
  if (fmMatch) {
    const tbl = fmMatch[1].trim()
    if (tbl) {
      const lines = tbl.split('\n').map(l => l.replace(/\|$/, '').trim()).filter(Boolean)
      if (lines.length >= 3) {
        const headerCells = lines[0].split('|').slice(1, -1).map(c => c.trim())
        const sepOk = lines[1].split('|').slice(1, -1).every(c => /^:?-+:?$/.test(c.trim()))
        if (sepOk) {
          const vals = lines[2].split('|').slice(1, -1).map(c => c.trim().replace(/\\\|/g, '|'))
          const obj = {}
          headerCells.forEach((k, i) => {
            const v = vals[i] || ''
            if (v === '' || v === '—') return
            obj[k] = v
          })
          fmRaw = serializeFrontmatter(obj)
        }
      }
    }
    body = body.replace(fmMatch[0], '').replace(/^\s*[\r\n]+/g, '').replace(/[\r\n]+\s*$/g, '')
  }
  const refsMatch = body.match(/<!--REFS_TABLE_BEGIN-->([\s\S]*?)<!--REFS_TABLE_END-->/)
  if (refsMatch) {
    refsRaw = refsMatch[1].trim()
    body = body.replace(refsMatch[0], '').replace(/^\s*[\r\n]+/g, '').replace(/[\r\n]+\s*$/g, '')
  }
  return { fmRaw, body: body.trim(), refsRaw }
}

// ————————————————————————————————————————————————————————————————
//  v2.2.70：[B] 双链表 → 编辑器正文底部 Markdown 表格（不进磁盘）
//  - HTML 注释 <!--REFS_TABLE_BEGIN-->...<!--REFS_TABLE_END--> 作为块标记
//  - wikilink 单元格用 [name](wikilink:encoded) 语法而非 [[name]]，避开 GFM 表转义
//    （[[ ]] 在 GFM 表里被反斜杠转义为 \[\[ \]，破坏渲染）
//  - 入链 / 出链各一个子表，列标题：页面 / 类型 / 关键属性
//  - 保存时被从正文剔除（不算用户内容）
// ————————————————————————————————————————————————————————————————
function renderRefsSectionMarkdown(refsOut, refsIn) {
  let refsMd = ''
  if (Array.isArray(refsOut) && refsOut.length) {
    refsMd += '\n\n**↗ 本页引用的页面**\n\n' + renderRefsTableMarkdown(refsOut)
  }
  if (Array.isArray(refsIn) && refsIn.length) {
    refsMd += '\n\n**🔗 引用本页的页面**\n\n' + renderRefsTableMarkdown(refsIn)
  }
  if (!refsMd) return ''
  return '<!--REFS_TABLE_BEGIN-->' + refsMd + '\n\n<!--REFS_TABLE_END-->'
}
function renderRefsTableMarkdown(refs) {
  const rows = refs.map(r => {
    const name = String(r.name || '').trim()
    if (!name) return ''
    const type = String(r.type || '').trim()
    const fields = Array.isArray(r.fields) ? r.fields : []
    const fieldCell = fields.map(f => f.label + '：' + f.value).filter(Boolean).join('、')
    // wikilink 用 [name](wikilink:encoded) 语法，wikiLinkPlugin 会把它渲染为可点击 pill
    const enc = encodeURIComponent(name)
    const wikiCell = '[' + escMdTable(name) + '](wikilink:' + enc + ')'
    const safeFields = escMdTable(fieldCell)
    const safeType = escMdTable(type)
    return '| ' + wikiCell + ' | ' + safeType + ' | ' + safeFields + ' |'
  }).filter(Boolean)
  if (!rows.length) return ''
  return '| 页面 | 类型 | 关键属性 |\n| --- | --- | --- |\n' + rows.join('\n')
}
  // ————————————————————————————————————————————————————————————————
//  DOM 事件接线（编辑器内双链点击 / 悬浮预览）
// ————————————————————————————————————————————————————————————————
function wireEditorDom() {
  if (wired) return
  wired = true
  const dom = editor.action(ctx => ctx.get(editorViewCtx)).dom
  // v2.2.70：frontmatter / 双链表 都已在正文内（含 wikilink），用统一监听即可
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
      if (name) bridge({ type: 'wikilink', name: name, anchor: anchor })
    }
  })
}

// ————————————————————————————————————————————————————————————————
//  Milkdown 编辑器构建 + 公开 API
// ————————————————————————————————————————————————————————————————
let buildPromise = null
async function buildEditor(editable) {
  if (buildPromise) return buildPromise
  buildPromise = (async () => {
    const e = await Editor.make(async ctx => {
      ctx.set(rootCtx, document.getElementById('editor'))
      ctx.set(defaultValueCtx, '')
    })
      .use(commonmark)
      .use(gfm)
      .use($prose(() => wikiLinkPlugin()))
      .use($prose(() => autocompletePlugin))
      .use($prose(() => autoPairPlugin))
      .config(ctx => {
        ctx.update(remarkStringifyOptionsCtx, prev => ({ ...prev, bullet: '-', listItemIndent: 'one', fences: true }))
      })
      .create()
    editor = e
    setEditable(editable !== false)
    wireEditorDom()
    return e
  })()
  return buildPromise
}

function setEditable(editable) {
  currentEditable = editable !== false
  if (editor) {
    editor.action(ctx => ctx.get(editorViewCtx).setProps({ editable: () => currentEditable }))
  }
}

function captureHeadings() {
  if (!editor) return
  const view = editor.action(ctx => ctx.get(editorViewCtx))
  const heads = []
  view.dom.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(h => {
    const t = (h.textContent || '').trim()
    if (t) heads.push(t)
  })
  window.__currentHeadings = Array.from(new Set(heads)).slice(0, 16)
}

function loadMarkdown(mdText, editable, mode, autoLink, pageName) {
  window.__currentPageName = (typeof pageName === 'string' && pageName.trim()) ? pageName.trim() : ''
  const sp = splitFrontmatter(mdText || '')
  pendingFrontmatter = sp.fmRaw
  currentFM = sp.fmRaw ? fmNormalize(parseFrontmatter(sp.fmRaw.split('\n').slice(1, -1))) : {}
  currentEditable = editable !== false
  // pageRefsOut / pageRefsIn 已由 WikiViewController 通过 setPageReferences(In|Out)
  // 在 loadMarkdown 之后调用（rebuildBody 会把它们注入正文末尾）。
  bridge({ type: 'getCustomTypes' })
  let userBody = sp.body || ''
  if (autoLink && AUTO_LINK_NAMES.length) userBody = autoLinkWiki(userBody, AUTO_LINK_NAMES)
  // v2.2.70：frontmatter 作为正文首段 Markdown 表注入（disk 仍存 YAML）
  const fmMd = renderFrontmatterMarkdownTable(currentFM)
  let composed = ''
  if (fmMd) composed += fmMd + '\n\n'
  composed += userBody.trimStart()
  const pre = preProcessWiki(composed)
  const finish = () => {
    editor.action(replaceAll(pre))
    editor.action(ctx => ctx.get(editorViewCtx).setProps({ editable: () => currentEditable }))
    // 双链表与 frontmatter Markdown 表同步进正文末尾
    injectRefsBlockIntoBody()
    captureHeadings()
  }
  if (!editor) {
    buildEditor(editable !== false).then(finish)
  } else {
    finish()
  }
}

// 把 refs block 注入正文末尾（如果 pageRefsOut / pageRefsIn 非空）
function injectRefsBlockIntoBody() {
  if (!editor) return
  const refsMd = renderRefsSectionMarkdown(pageRefsOut, pageRefsIn)
  if (!refsMd) return
  let body = editor.action(getMarkdown())
  body = postProcessWiki(body)
  // 先去掉已有的 refs 块（避免重复）
  body = body.replace(/<!--REFS_TABLE_BEGIN-->[\s\S]*?<!--REFS_TABLE_END-->\s*/g, '')
  body = body.replace(/\n{3,}/g, '\n\n').trim()
  body += '\n\n' + refsMd
  const pre = preProcessWiki(body)
  editor.action(replaceAll(pre))
}

// 重建正文（用于 setPageReferences 时刷新末尾 refs 表）
function rebuildBodyWithRefs() {
  if (!editor) return
  let body = editor.action(getMarkdown())
  body = postProcessWiki(body)
  body = body.replace(/<!--REFS_TABLE_BEGIN-->[\s\S]*?<!--REFS_TABLE_END-->\s*/g, '')
  body = body.replace(/\n{3,}/g, '\n\n').trim()
  const refsMd = renderRefsSectionMarkdown(pageRefsOut, pageRefsIn)
  if (refsMd) body += '\n\n' + refsMd
  const pre = preProcessWiki(body)
  editor.action(replaceAll(pre))
}

function requestSave() {
  if (!editor) return
  let body = editor.action(getMarkdown())
  body = postProcessWiki(body)
  body = body.replace(/\n{3,}/g, '\n\n').replace(/[ \t]+$/gm, '')
  // v2.2.70：从正文 Markdown 表反解 frontmatter，跳过 refs 装饰块
  const { fmRaw, body: userBody } = splitEditorBlocks(body)
  if (fmRaw) pendingFrontmatter = fmRaw
  const user = userBody.trim()
  let out = ''
  if (pendingFrontmatter) out += pendingFrontmatter + '\n'
  out += user
  bridge({ type: 'save', markdown: out.trimEnd() })
  return out.trimEnd()
}

function setMode() { /* Milkdown 始终为真·WYSIWYG（markdown-native），无需切换 */ }

function scrollToAnchor(anchor) {
  const a = (anchor || '').trim()
  if (!a || !editor) return
  const view = editor.action(ctx => ctx.get(editorViewCtx))
  const heads = view.dom.querySelectorAll('h1,h2,h3,h4,h5,h6')
  let target = null
  heads.forEach(h => { if (!target && h.textContent.trim().toLowerCase() === a.toLowerCase()) target = h })
  if (!target) {
    try { target = view.dom.querySelector('#' + CSS.escape(a)) } catch (e) {}
  }
  if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function appendWikiLink(name) {
  if (!editor) return
  const target = (name || '').trim()
  if (!target) return
  const enc = encodeURIComponent(target)
  const md = '[' + target + '](wikilink:' + enc + ')'
  editor.action(ctx => {
    const view = ctx.get(editorViewCtx)
    const doc = ctx.get(parserCtx)(md)
    if (!doc) return
    const end = view.state.doc.content.size
    view.dispatch(view.state.tr.insert(end, doc.content).scrollIntoView())
  })
  if (window.MMEditor && window.MMEditor.requestSave) window.MMEditor.requestSave()
}

function setWikiPages(arr) {
  WIKIPAGES = Array.isArray(arr) ? arr : []
  window.__wikiPages = WIKIPAGES
}
function setAutoLinkNames(arr) {
  AUTO_LINK_NAMES = Array.isArray(arr) ? arr : []
}
function setPageReferences(arr) {
  pageRefsIn = Array.isArray(arr) ? arr : []
  rebuildBodyWithRefs()
}
function setPageReferencesOut(arr) {
  pageRefsOut = Array.isArray(arr) ? arr : []
  rebuildBodyWithRefs()
}
function setCustomTypes(arr, selectName) {
  CUSTOM_TYPES = Array.isArray(arr) ? arr : []
  renderBanner()
  if (selectName) {
    const sel = document.querySelector('select[data-fm="type"]')
    if (sel) { sel.value = selectName; sel.dispatchEvent(new Event('change', { bubbles: true })) }
  }
}

// ⌘S 保存
document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
    e.preventDefault()
    if (window.MMEditor) window.MMEditor.requestSave()
  }
})

window.MMEditor = {
  init() { buildEditor(true) },
  getEditor() { return editor },
  loadMarkdown,
  requestSave,
  setMode,
  scrollToAnchor,
  appendWikiLink,
  setWikiPages,
  setAutoLinkNames,
  setPageReferences,
  setPageReferencesOut,
  setCustomTypes,
  showPreview(name, html) { window.MMEditor_showPreview(name, html) },
  requestCurrentMarkdown() {
    if (!editor) return pendingFrontmatter || ''
    let body = editor.action(getMarkdown())
    body = postProcessWiki(body)
    body = body.replace(/\n{3,}/g, '\n\n').replace(/[ \t]+$/gm, '')
    // v2.2.70：从正文 Markdown 表反解 frontmatter
    const { fmRaw, body: userBody } = splitEditorBlocks(body)
    if (fmRaw) pendingFrontmatter = fmRaw
    const user = userBody.trim()
    let out = ''
    if (pendingFrontmatter) out += pendingFrontmatter + '\n'
    out += user
    return out.trimEnd()
  }
}

window.addEventListener('DOMContentLoaded', function () {
  if (window.MMEditor) window.MMEditor.init()
  window.loadMarkdown = function (md, editable, mode, autoLink, pageName) { return window.MMEditor.loadMarkdown(md, editable, mode, autoLink, pageName) }
  window.requestSave = function () { return window.MMEditor.requestSave() }
  window.setMode = function (m) { return window.MMEditor.setMode(m) }
  bridge({ type: 'getPages' })
})
