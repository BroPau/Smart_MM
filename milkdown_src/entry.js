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
    const cap = fmCanonical(key)
    if (val === '') {
      const items = []
      let j = i + 1
      while (j < lines.length) {
        const st = lines[j].match(/^\s+-\s+(.*)$/)
        if (st) { items.push(st[1].trim()); j++; continue }
        break
      }
      if (items.length) {
        fm[key] = FM_WIKILINK_KEYS[cap] ? items.map(parseWikilinkItem) : items
      }
      i = j
    } else {
      // 行内列表检测：[a, b, c] / [a, b]（排除 wikilink 形式 "[..](wikilink:..)"）
      const isInlineList = /^\[.*\]$/.test(val) && val.indexOf('](wikilink:') < 0 &&
        (val.indexOf(',') >= 0 || cap === 'aliases' || cap === 'tags')
      if (isInlineList) {
        const inner = val.slice(1, -1).trim()
        fm[key] = inner === '' ? [] : inner.split(',').map(x => x.trim()).filter(Boolean)
      } else if (FM_WIKILINK_KEYS[cap]) {
        fm[key] = parseWikilinkItem(val)
      } else {
        fm[key] = val
      }
      i++
    }
  }
  return fm
}
const KEY_ALIASES = {
  // canonical 小写英文 → 自身（identity）
  type: 'type', canonical_name: 'canonical_name', canonicalname: 'canonical_name',
  aliases: 'aliases', tags: 'tags', updated: 'updated', backlinks: 'backlinks',
  company: 'company', title: 'title', summary: 'summary',
  suspected_alias_of: 'suspected_alias_of',
  // 旧中文标签 → canonical
  类型: 'type', 规范名: 'canonical_name', 别名: 'aliases', 标签: 'tags',
  更新时间: 'updated', 反向链接: 'backlinks', 公司: 'company', 职位: 'title',
  // 中文专属键 → canonical（identity，保持中文内部键稳定）
  中文名: '中文名', 职能范围: '职能范围', 公司类型: '公司类型',
  所属行业: '所属行业', 公司简介: '公司简介', 品牌: '品牌',
  具体型号: '具体型号', 类别: '类别', 功能简述: '功能简述', 状态: '状态', 替代料: '替代料',
  // v2.2.72：纯英文 PascalCase 显示键 → canonical（磁盘统一 PascalCase 后仍能正确归一）
  Type: 'type', CanonicalName: 'canonical_name', Aliases: 'aliases',
  Tags: 'tags', Updated: 'updated', Backlinks: 'backlinks', Company: 'company', Title: 'title',
  Summary: 'summary', SuspectedAliasOf: 'suspected_alias_of',
  ChineseName: '中文名', FunctionScope: '职能范围', CompanyType: '公司类型',
  Industry: '所属行业', CompanyProfile: '公司简介', Brand: '品牌',
  Model: '具体型号', Category: '类别', Description: '功能简述', Status: '状态', Alternative: '替代料',
}
function fmCanonical(k) { return KEY_ALIASES[k] || k }
// canonical（内部稳定键）→ 纯英文 PascalCase 显示键（v2.2.72：frontmatter 不再中英文混合）
const FM_DISPLAY = {
  type: 'Type', canonical_name: 'CanonicalName', aliases: 'Aliases',
  tags: 'Tags', updated: 'Updated', backlinks: 'Backlinks',
  company: 'Company', title: 'Title', summary: 'Summary',
  suspected_alias_of: 'SuspectedAliasOf',
  中文名: 'ChineseName', 职能范围: 'FunctionScope', 公司类型: 'CompanyType',
  所属行业: 'Industry', 公司简介: 'CompanyProfile', 品牌: 'Brand',
  具体型号: 'Model', 类别: 'Category', 功能简述: 'Description', 状态: 'Status', 替代料: 'Alternative',
}
function fmDisplayName(k) {
  if (FM_DISPLAY[k]) return FM_DISPLAY[k]
  // ASCII 兜底：首字母大写（保持纯英文），避免落入中文混合
  if (/^[A-Za-z0-9_]+$/.test(k)) return k.charAt(0).toUpperCase() + k.slice(1)
  return k
}
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
// v2.2.73：frontmatter 中「页面引用型」字段——其值本就是 Wiki 页名，
// 在编辑器内渲染为可点击双链（仅显示层用 wikilink 语法，磁盘仍存纯页名）
const FM_WIKILINK_KEYS = { company: 1, alternative: 1, suspected_alias_of: 1 }
// 把单个值转成（display=显示层 wikilink 语法 / disk=磁盘纯页名）
function itemToWikilink(v, display) {
  let s = (v == null) ? '' : String(v).trim()
  const m = /^\[([^\]]*)\]\(wikilink:([^)\s]+)\)$/.exec(s)
  let page = m ? m[2] : s
  try { page = decodeURIComponent(page) } catch (e) {}
  if (!display) return yamlScalar(page)
  if (WIKIPAGES.length && WIKIPAGES.some(p => p.toLowerCase() === page.toLowerCase())) {
    const enc = encodeURIComponent(page)
    return '"[' + page + '](wikilink:' + enc + ')"'
  }
  return yamlScalar(page)
}
// 从（可能带 wikilink 语法的）字符串里解析回纯页名
function parseWikilinkItem(s) {
  if (typeof s !== 'string') return String(s)
  let t = s.trim()
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) t = t.slice(1, -1).trim()
  const m = /^\[([^\]]*)\]\(wikilink:([^)\s]+)\)$/.exec(t)
  if (m) { try { return decodeURIComponent(m[2]) } catch (e) { return m[2] } }
  return t
}
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

// ProseMirror 插件：YAML 代码块语法高亮（v2.2.72，零依赖自绘装饰）
const yamlHighlightKey = new PluginKey('yamlHighlight')
function classifyYamlValue(s) {
  const t = s.trim()
  if (t === '') return 'yml-v'
  if (t.startsWith('#')) return 'yml-c'
  if (/^".*"$/.test(t) || /^'.*'$/.test(t)) return 'yml-s'
  if (/^-?\d+(\.\d+)?$/.test(t)) return 'yml-n'
  if (t === 'true' || t === 'false' || t === 'null' || t === '~') return 'yml-n'
  return 'yml-v'
}
function yamlHighlightPlugin() {
  return new Plugin({
    key: yamlHighlightKey,
    props: {
      decorations(state) {
        const decos = []
        state.doc.descendants((node, pos) => {
          if (node.type.name !== 'code_block' && node.type.name !== 'codeBlock') return
          const lang = (node.attrs && (node.attrs.language || node.attrs.lang)) || ''
          const text = node.textContent
          const isYaml = lang === 'yaml' || lang === 'yml'
          if (!isYaml) return
          const lines = text.split('\n')
          let offset = pos + 1 // code_block 内容首字符位置
          for (const line of lines) {
            const lineStart = offset
            if (line.length === 0) { offset += 1; continue }
            const kvM = /^(\s*)([A-Za-z_][A-Za-z0-9_]*):(\s*)(.*)$/.exec(line)
            if (kvM) {
              const keyStart = lineStart + kvM[1].length
              const keyEnd = keyStart + kvM[2].length
              decos.push(Decoration.inline(keyStart, keyEnd, { class: 'yml-k' }))
              const sepStart = keyEnd
              const sepEnd = sepStart + 1
              decos.push(Decoration.inline(sepStart, sepEnd, { class: 'yml-sep' }))
              const valStr = kvM[4]
              if (valStr.length) {
                const valStart = sepEnd + kvM[3].length
                const valEnd = valStart + valStr.length
                decos.push(Decoration.inline(valStart, valEnd, { class: classifyYamlValue(valStr) }))
              }
            } else {
              const dashM = /^\s*-\s+/.exec(line)
              if (dashM) {
                const dashStart = lineStart + dashM[0].length - 1
                decos.push(Decoration.inline(dashStart, dashStart + 1, { class: 'yml-dash' }))
                const rest = line.slice(dashM[0].length)
                if (rest.length) {
                  const rs = lineStart + dashM[0].length
                  decos.push(Decoration.inline(rs, rs + rest.length, { class: classifyYamlValue(rest) }))
                }
              } else if (/^\s*#/.test(line)) {
                decos.push(Decoration.inline(lineStart, lineStart + line.length, { class: 'yml-c' }))
              }
            }
            offset += line.length + 1 // +1 换行
          }
        })
        return DecorationSet.create(state.doc, decos)
      }
    }
  })
}

// ProseMirror 插件：隐藏 frontmatter / refs 表的 HTML 注释边界标记（<!--FM_TABLE_*-->、<!--REFS_TABLE_*-->）
// 仅视觉隐藏（display:none），绝不从文档移除——这些标记是保存时反解 YAML / refs 的边界，磁盘不写。
const fmMarkerKey = new PluginKey('fmMarker')
const FM_MARKER_RE = /<!--(FM_TABLE_BEGIN|FM_TABLE_END|REFS_TABLE_BEGIN|REFS_TABLE_END)-->/
// Milkdown 把 <!-- ... --> 注释节点映射为 type="html" 的 inline atom 节点（见 bundle htmlSchema：
// $nodeSchema("html")，attrs:{value}，toDOM 渲染为 <span data-type="html" data-value>{value}</span>）。
// 这是 leaf 节点、无 children，node.textContent 恒为 ''——所以必须优先从 node.attrs.value 取 HTML 字符串。
// 不硬编码 type 名（不同 milkdown 版本可能叫 html/html_block/html_inline），统一探测 attrs.value 即可。
function fmMarkerPlugin() {
  return new Plugin({
    key: fmMarkerKey,
    props: {
      decorations(state) {
        const decos = []
        state.doc.descendants((node, pos) => {
          let raw = ''
          if (node.isText) {
            raw = node.text || ''
          } else if (node.attrs && typeof node.attrs.value === 'string' && node.attrs.value) {
            raw = node.attrs.value
          } else {
            raw = node.textContent || ''
          }
          if (raw && FM_MARKER_RE.test(raw)) {
            decos.push(Decoration.node(pos, pos + node.nodeSize, { class: 'fm-hidden' }))
            return false
          }
        })
        return DecorationSet.create(state.doc, decos)
      }
    }
  })
}

// ProseMirror 插件：YAML 代码块内的 [text](wikilink:Page) 文本装饰为可点击双链
// （代码块内没有 link mark，wikiLinkPlugin 不会命中，这里单独处理 frontmatter 的页面引用字段）
const wikilinkInCodeKey = new PluginKey('wikilinkInCode')
const IN_CODE_WL_RE = /\[([^\]]*)\]\(wikilink:([^)\s]+)\)/g
function wikilinkInsideCodePlugin() {
  return new Plugin({
    key: wikilinkInCodeKey,
    props: {
      decorations(state) {
        const decos = []
        state.doc.descendants((node, pos) => {
          if (node.type.name !== 'code_block' && node.type.name !== 'codeBlock') return
          const lang = (node.attrs && (node.attrs.language || node.attrs.lang)) || ''
          if (lang !== 'yaml' && lang !== 'yml') return
          const text = node.textContent
          const base = pos + 1
          let m
          IN_CODE_WL_RE.lastIndex = 0
          while ((m = IN_CODE_WL_RE.exec(text)) !== null) {
            const start = base + m.index
            const end = start + m[0].length
            let page = m[2]
            try { page = decodeURIComponent(page) } catch (e) {}
            const missing = page && WIKIPAGES.length && !WIKIPAGES.some(p => p.toLowerCase() === page.toLowerCase())
            decos.push(Decoration.inline(start, end, {
              class: 'wikilink' + (missing ? ' wikilink-missing' : ''),
              'data-wikilink': page,
              'data-page': page
            }))
          }
        })
        return DecorationSet.create(state.doc, decos)
      }
    }
  })
}
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

function serializeFrontmatter(fm, mode) {
  if (!fm || Object.keys(fm).length === 0) return ''
  const display = mode !== 'disk'  // display=编辑器内 wikilink 语法；disk=纯页名（pipeline 兼容）
  const lines = ['---']
  fmOrderedKeys(fm).filter(k => !FM_SKIP[k]).forEach(k => {
    const dk = fmDisplayName(k)        // 纯英文 PascalCase 显示键（v2.2.72）
    const v = fm[k]
    if (v === undefined || v === null) return
    const cap = fmCanonical(k)
    if (FM_WIKILINK_KEYS[cap]) {
      // 页面引用型字段：display 渲染为可点击双链，disk 落纯页名
      if (Array.isArray(v)) {
        if (v.length === 0) { lines.push(dk + ': []'); return }
        lines.push(dk + ':')
        v.forEach(item => lines.push('  - ' + itemToWikilink(item, display)))
      } else {
        const s = String(v).trim()
        if (s === '') { lines.push(dk + ': ""'); return }
        lines.push(dk + ': ' + itemToWikilink(s, display))
      }
      return
    }
    if (Array.isArray(v)) {
      if (v.length === 0) { lines.push(dk + ': []'); return }
      if (cap === 'aliases' || cap === 'tags') {
        // 别名 / 标签：行内逗号隔离（v2.2.73），更符合 Obsidian 习惯
        lines.push(dk + ': [' + v.map(x => yamlScalar(x)).join(', ') + ']')
      } else {
        lines.push(dk + ':')
        v.forEach(item => lines.push('  - ' + yamlScalar(item)))
      }
    } else {
      const s = String(v)
      if (s === '') { lines.push(dk + ': ""'); return }
      lines.push(dk + ': ' + yamlScalar(s))
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
//  v2.2.71 [A] frontmatter → 编辑器正文内「YAML 源码」渲染（磁盘仍为 YAML）
//  - 渲染形态：<!--FM_TABLE_BEGIN--> 块里包 ```yaml\n---\n<yaml>\n---\n```
//    → Milkdown 把它当 fenced code block 渲染 → 等宽字体 + 代码块边框
//  - 切回原 banner 模式：把 fmRenderMode 设回 'table'（v2.2.70 旧形态）
//  - 加载：currentFM → serializeFrontmatter → 嵌进 yaml fence
//  - 保存：splitEditorBlocks 从 fence 反解 YAML → 重新生成 frontmatter 文本
//  - HTML 注释作为磁盘边界（绝不写盘），即使用户手改了 fence 里的内容
// ————————————————————————————————————————————————————————————————
const fmRenderMode = 'yaml'  // 'yaml' = 直接渲染 YAML 源码（v2.2.71）｜ 'table' = 旧表格
function renderFrontmatterMarkdownTable(fm) {
  if (!fm || typeof fm !== 'object') return ''
  const keys = fmOrderedKeys(fm).filter(k => !FM_SKIP[k])
  if (keys.length === 0) return ''
  if (fmRenderMode === 'yaml') {
    // 直接渲染 YAML 源码：等宽字体让 key/value 清晰可读
    const yamlText = serializeFrontmatter(fm, 'display')
    if (!yamlText) return ''
    return '<!--FM_TABLE_BEGIN-->\n\n```yaml\n' + yamlText + '\n```\n\n<!--FM_TABLE_END-->'
  }
  // fallback：旧 table 形态（保留以备回退）
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
    const inner = fmMatch[1].trim()
    if (inner) {
      // v2.2.71 优先：抽出 ```yaml\n---\n...\n---\n``` 块直接当作 YAML 文本
      const fence = inner.match(/```(?:yaml|yml)?\n([\s\S]*?)\n```/)
      if (fence) {
        const yamlText = fence[1].trim()
        // v2.2.73：反解为规范磁盘形态（页面引用字段落纯页名、别名行内化），
        // 避免磁盘残留 wikilink 语法（pipeline 仍按纯页名解析）
        const norm = (yamlText.startsWith('---') ? yamlText : '---\n' + yamlText + '\n---')
        const parsed = parseFrontmatter(norm.split('\n').slice(1, -1))
        fmRaw = serializeFrontmatter(parsed, 'disk')
      } else {
        // 兼容 v2.2.70 旧 table 形态
        const lines = inner.split('\n').map(l => l.replace(/\|$/, '').trim()).filter(Boolean)
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
            fmRaw = serializeFrontmatter(obj, 'disk')
          }
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
    // v2.2.73：精简为「页面 + 类型」两列，去掉冗余的「关键属性」列
    // wikilink 用 [name](wikilink:encoded) 语法，wikiLinkPlugin 会把它渲染为可点击 pill
    const enc = encodeURIComponent(name)
    const wikiCell = '[' + escMdTable(name) + '](wikilink:' + enc + ')'
    const safeType = escMdTable(type)
    return '| ' + wikiCell + ' | ' + safeType + ' |'
  }).filter(Boolean)
  if (!rows.length) return ''
  return '| 页面 | 类型 |\n| --- | --- |\n' + rows.join('\n')
}
  // ————————————————————————————————————————————————————————————————
//  DOM 事件接线（编辑器内双链点击 / 悬浮预览）
// ————————————————————————————————————————————————————————————————
function wireEditorDom() {
  if (wired) return
  wired = true
  const dom = editor.action(ctx => ctx.get(editorViewCtx)).dom
  // v2.2.71 关键修正：v2.2.70 的 wikiLinkPlugin 是给 text 节点加 class="wikilink"，
  // 实际渲染的 <a> 元素本身没 wikilink 类。旧选择器 `a.wikilink` 永远匹不到。
  // 新选择器：.wikilink 装饰的 span/text 或 href 协议为 wikilink: 的 <a> 都能命中。
  const findWikilink = (node) => node && node.closest
    ? node.closest('.wikilink, a[href^="wikilink:"]')
    : null
  dom.addEventListener('mouseover', e => {
    const el = findWikilink(e.target)
    if (el) showPreviewFor(el)
  })
  dom.addEventListener('mouseout', e => {
    const el = findWikilink(e.target)
    if (el) hidePreviewSoon()
  })
  dom.addEventListener('click', e => {
    const el = findWikilink(e.target)
    if (el) {
      e.preventDefault()
      let name = el.getAttribute('data-page') || el.getAttribute('data-wikilink') || ''
      let anchor = el.getAttribute('data-anchor') || ''
      if (!name) {
        // 退路：从最近的 <a href="wikilink:..."> 取 target
        const a = el.matches && el.matches('a[href^="wikilink:"]')
          ? el
          : (el.parentElement && el.parentElement.closest
              ? el.parentElement.closest('a[href^="wikilink:"]')
              : null)
        const href = (a && a.getAttribute('href')) || ''
        if (href.startsWith('wikilink:')) {
          const enc = href.slice('wikilink:'.length)
          try { name = decodeURIComponent(enc) } catch (err) { name = enc }
        }
      }
      if (name) {
        const h = name.indexOf('#')
        if (h >= 0) { anchor = name.slice(h + 1).trim(); name = name.slice(0, h).trim() }
        bridge({ type: 'wikilink', name, anchor })
      }
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
      .use($prose(() => yamlHighlightPlugin()))
      .use($prose(() => fmMarkerPlugin()))
      .use($prose(() => wikilinkInsideCodePlugin()))
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
