// Milkdown engine prototype — validates the approach before full port.
// Wikilink strategy: pre-process [[target|alias]] -> [alias](wikilink:ENCODED)
// and post-process back on serialize. Frontmatter is split at the JS boundary.
import { Editor, rootCtx, defaultValueCtx, editorViewCtx, remarkStringifyOptionsCtx } from '@milkdown/core'
import { commonmark } from '@milkdown/preset-commonmark'
import { gfm } from '@milkdown/preset-gfm'
import { getMarkdown, replaceAll, $prose } from '@milkdown/utils'
import { Plugin, PluginKey } from '@milkdown/prose/state'
import { Decoration, DecorationSet } from '@milkdown/prose/view'

// ---------- wikiPages (for missing-page detection & autocomplete) ----------
let WIKIPAGES = []
let AUTO_LINK_NAMES = []

// ---------- frontmatter boundary ----------
function splitFrontmatter(md) {
  const lines = (md || '').replace(/\r\n/g, '\n').split('\n')
  if (lines[0] && lines[0].trim() === '---') {
    let i = 1
    while (i < lines.length && lines[i].trim() !== '---') i++
    if (i < lines.length) {
      const fmRaw = lines.slice(0, i + 1).join('\n')
      const body = lines.slice(i + 1).join('\n').replace(/^\n+/, '')
      return { fmRaw, body }
    }
  }
  return { fmRaw: '', body: md || '' }
}

// [[target|alias]] or [[target]] -> [alias](wikilink:ENCODED)
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
// reverse: [alias](wikilink:ENCODED) -> [[target|alias]] or [[target]]
function postProcessWiki(md) {
  const LINK_RE = /\[([^\]]*)\]\(wikilink:([^)\s]+)\)/g
  return md.replace(LINK_RE, (_, alias, enc) => {
    const target = decodeURIComponent(enc)
    if (alias === target) return '[[' + target + ']]'
    return '[[' + target + '|' + alias + ']]'
  })
}

// ---------- ProseMirror plugin: style + click wikilinks ----------
const wikiKey = new PluginKey('milkdownWikilink')
function wikiLinkPlugin() {
  return new Plugin({
    key: wikiKey,
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
          const missing = WIKIPAGES.length && !WIKIPAGES.some(p => p.toLowerCase() === target.toLowerCase())
          const cls = 'wikilink' + (missing ? ' wikilink-missing' : '')
          decos.push(Decoration.inline(pos, pos + node.nodeSize, { class: cls, 'data-wikilink': target }))
        })
        return DecorationSet.create(state.doc, decos)
      },
      handleClick(view, pos, event) {
        const el = event.target
        if (el && el.closest) {
          const a = el.closest('a.wikilink, span.wikilink')
          if (a) {
            const target = a.getAttribute('data-wikilink') || a.textContent
            const anchor = target.startsWith('#') ? target.slice(1) : null
            const name = target.startsWith('#') ? '' : target
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
              window.webkit.messageHandlers.editorBridge.postMessage({ type: 'wikilink', name, anchor })
            }
            return true
          }
        }
        return false
      }
    }
  })
}

let editor = null
let pendingFrontmatter = ''
let currentEditable = true

async function buildEditor(editable) {
  const e = await Editor.make(async ctx => {
    ctx.set(rootCtx, document.getElementById('editor'))
    ctx.set(defaultValueCtx, '')
  })
    .use(commonmark)
    .use(gfm)
    .use($prose(() => wikiLinkPlugin()))
    .config(ctx => {
      ctx.update(remarkStringifyOptionsCtx, prev => ({
        ...prev,
        bullet: '-',
        listItemIndent: 'one',
        fences: true
      }))
    })
    .create()
  editor = e
  setEditable(editable !== false)
  return e
}

function setEditable(editable) {
  currentEditable = editable !== false
  if (editor) {
    editor.action(ctx => ctx.get(editorViewCtx).setProps({ editable: () => currentEditable }))
  }
}

function loadMarkdown(mdText, editable, mode, autoLink, pageName) {
  const sp = splitFrontmatter(mdText || '')
  pendingFrontmatter = sp.fmRaw
  currentEditable = editable !== false
  let body = sp.body || ''
  if (autoLink && AUTO_LINK_NAMES.length) {
    // (auto-link ported later)
  }
  const pre = preProcessWiki(body)
  if (!editor) {
    buildEditor(editable !== false).then(() => {
      editor.action(replaceAll(pre))
      editor.action(ctx => ctx.get(editorViewCtx).setProps({ editable: () => currentEditable }))
    })
  } else {
    editor.action(replaceAll(pre))
    editor.action(ctx => ctx.get(editorViewCtx).setProps({ editable: () => currentEditable }))
  }
}

function requestSave() {
  if (!editor) return
  let body = editor.action(getMarkdown())
  body = postProcessWiki(body)
  body = body.replace(/\n{3,}/g, '\n\n').replace(/[ \t]+$/gm, '')
  const out = (pendingFrontmatter ? pendingFrontmatter + '\n' : '') + body
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
    window.webkit.messageHandlers.editorBridge.postMessage({ type: 'save', markdown: out.trimEnd() })
  }
  return out.trimEnd()
}

function setWikiPages(arr) { WIKIPAGES = Array.isArray(arr) ? arr : [] }

async function init() {
  await buildEditor(true)
  window.MMEditor = {
    loadMarkdown, requestSave,
    setMode() {},
    setWikiPages,
    setAutoLinkNames(a) { AUTO_LINK_NAMES = Array.isArray(a) ? a : [] },
    setPageReferences() {}, setPageReferencesOut() {},
    appendWikiLink(name) {
      if (!editor || !name) return
      const txt = '[' + name + '](wikilink:' + encodeURIComponent(name) + ')'
      editor.action(ctx => ctx.get(editorViewCtx).dispatch(ctx.get(editorViewCtx).state.tr.insertText(txt).scrollIntoView()))
      requestSave()
    },
    scrollToAnchor() {}, setCustomTypes() {}, showPreview() {}
  }
  window.loadMarkdown = (md, ed, m, al, pn) => loadMarkdown(md, ed, m, al, pn)
  window.requestSave = () => requestSave()
  window.setMode = () => {}
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
    window.webkit.messageHandlers.editorBridge.postMessage({ type: 'getPages' })
  }
}

export { init, loadMarkdown, requestSave }
