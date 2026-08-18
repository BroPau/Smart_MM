//
//  MarkdownEditorView.swift
//  Meetinsight
//
//  Obsidian / Typora 式「所见即所得」Markdown 编辑器（纯本地、离线可用）：
//  - 底层由离线内置的 Vditor 引擎驱动（Lute 渲染内核，位于 Resources/vditor）。
//  - 默认模式 = IR（Instant Rendering，即 Obsidian 的「实时预览」：保留 Markdown 源码、
//    语法符号淡显、标题/列表/代码块/引用/图片即时渲染）。
//  - 工具栏「模式」按钮可在 IR(实时预览) / WYSIWYG(Typora 真·所见即所得) / SV(分屏) 间切换。
//  - [[双链]] 渲染为可点击 pill，点击经 editorBridge 通知宿主跳转。
//  - [[name|alias]] 解析为：跳转目标 = 左侧 name，显示文字 = 右侧 alias。
//  - YAML frontmatter 顶部渲染为「页面属性」信息卡（与旧版一致），编辑区只放正文，
//    保存时自动回贴 frontmatter，源文件不被破坏。
//  - 通过 WKWebView messageHandlers 与宿主双向通信；深色模式跟随系统外观。
//

import Cocoa
import WebKit

protocol MarkdownEditorViewDelegate: AnyObject {
    /// 用户点击「保存」后触发，回传当前编辑的 Markdown 源码（含 frontmatter）。
    func markdownEditorDidRequestSave(_ editor: MarkdownEditorView, markdown: String)
    /// 用户点击预览中的 [[双链]] 时触发。anchor 为 Obsidian 式 [[Page#Heading]] 的标题锚点（可选）。
    func markdownEditorDidClickWikilink(_ editor: MarkdownEditorView, name: String, anchor: String?)
    /// 编辑器初始化时请求现有页面名列表（用于双链自动完成与缺失页判定）。
    func markdownEditorRequestsPageList(_ editor: MarkdownEditorView) -> [String]
    /// 悬浮预览双链时，返回目标页正文（Markdown，已剥离 frontmatter）；页面不存在返回 nil。
    func markdownEditorPreviewForWikilink(_ editor: MarkdownEditorView, name: String) -> String?
    /// 用户点击 banner 上的「✏️ 编辑属性」按钮，宿主应当弹出属性编辑面板并落盘新 frontmatter。
    /// （默认 no-op —— 仅 WikiViewController 关心；纪要页未实现。）
    func markdownEditorDidRequestEditProperties(_ editor: MarkdownEditorView, markdown: String)
}

/// 接收 WKWebView 的 JS 消息，转发到主线程闭包。
fileprivate final class EditorMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: (([String: Any]) -> Void)?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(dict)
        }
    }
}

/// 默认 no-op：让 markdownEditorDidRequestEditProperties 在纪要页等不需要编辑属性的场景下不必实现
extension MarkdownEditorViewDelegate {
    func markdownEditorDidRequestEditProperties(_ editor: MarkdownEditorView, markdown: String) {}
}

final class MarkdownEditorView: NSView, WKNavigationDelegate {

    weak var delegate: MarkdownEditorViewDelegate?

    private let webView: WKWebView
    private let handler = EditorMessageHandler()

    private var didLoad = false
    private var pendingMarkdown: String?
    private var pendingEditable: Bool = true
    private var pendingMode: String = "ir"
    private var pendingAutoLink: Bool = false

    override init(frame frameRect: NSRect) {
        let cfg = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.add(handler, name: "editorBridge")
        cfg.userContentController = uc
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        let cfg = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.add(handler, name: "editorBridge")
        cfg.userContentController = uc
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // 关键：禁用所有缓存。理由：用户重启 app 仍可能看到旧 banner 英文 label，
        // 是因为 WKWebView 默认会缓存 loadHTMLString 的 HTML 模板与 %TIPTAP_BASE% 子资源。
        // 关掉后每次 setup 都从磁盘读最新模板 + 最新 tiptap.bundle.js，
        // 确保 bundle 替换立即生效（v2.2.30 部署铁律）。
        cfg.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init(coder: coder)
        setup()
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editorBridge")
    }

    private func setup() {
        wantsLayer = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // 透明背景，跟随系统外观
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        handler.onMessage = { [weak self] msg in
            self?.handle(message: msg)
        }
        let engine = Self.engine
        if engine == "tiptap", let base = Self.tiptapBaseURL() {
            var html = TipTapEditorHTML.template
            html = html.replacingOccurrences(of: "%TIPTAP_BASE%",
                                            with: base.absoluteString)
            webView.loadHTMLString(html, baseURL: base)
        } else if let base = Self.vditorBaseURL() {
            var html = EditorHTML.template
            html = html.replacingOccurrences(of: "%VDITOR_CDN%",
                                            with: base.absoluteString)
            webView.loadHTMLString(html, baseURL: base)
        } else {
            // 兜底：编辑引擎资源缺失时给出可读报错，避免白屏无提示
            webView.loadHTMLString("<html><body style='font-family:sans-serif;padding:24px;color:#b00'>编辑器资源缺失：Resources/tiptap 或 Resources/vditor 未打包进 App。</body></html>", baseURL: nil)
        }
    }

    // MARK: - 公开 API

    /// 载入并渲染 Markdown。editable=false 时预览区不可编辑（如搜索结果）。
    /// mode 可选：'ir'(实时预览,默认) / 'wysiwyg'(真·所见即所得) / 'sv'(分屏)。
    /// autoLink=true 时（仅纪要页单人纪要用），加载时会把正文里出现的已知 Wiki 页名裸词自动包裹为 [[名称]]。
    func load(markdown: String, editable: Bool = true, mode: String = "ir", autoLink: Bool = false) {
        pendingMarkdown = markdown
        pendingEditable = editable
        pendingMode = mode
        pendingAutoLink = autoLink
        if didLoad {
            webView.evaluateJavaScript("loadMarkdown(\(jsString(markdown)), \(jsBool(editable)), \(jsString(mode)), \(jsBool(autoLink)))")
        }
    }

    /// 切换编辑模式（ir / wysiwyg / sv）。
    func setMode(_ mode: String) {
        pendingMode = mode
        webView.evaluateJavaScript("setMode(\(jsString(mode)))")
    }

    /// 触发保存：读取当前编辑内容（含 frontmatter）并回传宿主。
    func requestSave() {
        webView.evaluateJavaScript("requestSave()")
    }

    /// 推送现有页面名列表给 JS（双链自动完成 + 缺失页判定）。
    func setWikiPages(_ names: [String]) {
        guard Self.engine == "tiptap" else { return }
        let json = (try? JSONSerialization.data(withJSONObject: names)) ?? Data("[]".utf8)
        let js = String(data: json, encoding: .utf8) ?? "[]"
        webView.evaluateJavaScript("MMEditor.setWikiPages(\(js))")
    }

    /// 推送「自动双链」目标名列表（仅 Wiki 页名）给 JS；加载纪要时把正文里出现的裸词包裹为 [[名称]]。
    func setAutoLinkNames(_ names: [String]) {
        guard Self.engine == "tiptap" else { return }
        let json = (try? JSONSerialization.data(withJSONObject: names)) ?? Data("[]".utf8)
        let js = String(data: json, encoding: .utf8) ?? "[]"
        webView.evaluateJavaScript("MMEditor.setAutoLinkNames(\(js))")
    }

    /// 推送「反向链接 / incoming」列表给 JS：即所有在正文里 [[引用了本页]] 的页面名（由宿主扫描得到）。
    /// JS 侧会把它与本页 frontmatter 的手动 backlinks 字段合并去重展示，并支持手动追加。
    func setBacklinks(_ names: [String]) {
        guard Self.engine == "tiptap" else { return }
        let json = (try? JSONSerialization.data(withJSONObject: names)) ?? Data("[]".utf8)
        let js = String(data: json, encoding: .utf8) ?? "[]"
        webView.evaluateJavaScript("MMEditor.setBacklinks(\(js))")
    }

    /// 跳转到 Wiki 页内某标题锚点（Obsidian 式 [[Page#Heading]]）；无匹配标题时静默忽略。
    func scrollToAnchor(_ anchor: String) {
        guard Self.engine == "tiptap", !anchor.isEmpty else { return }
        let js = "MMEditor.scrollToAnchor(\(jsString(anchor)))"
        webView.evaluateJavaScript(js)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didLoad = true
        if let pending = pendingMarkdown {
            pendingMarkdown = nil
            webView.evaluateJavaScript("loadMarkdown(\(jsString(pending)), \(jsBool(pendingEditable)), \(jsString(pendingMode)), \(jsBool(pendingAutoLink)))")
        }
    }

    // MARK: - 内部

    private func handle(message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "save":
            if let md = message["markdown"] as? String {
                delegate?.markdownEditorDidRequestSave(self, markdown: md)
            }
        case "wikilink":
            if let name = message["name"] as? String {
                let anchor = message["anchor"] as? String
                delegate?.markdownEditorDidClickWikilink(self, name: name, anchor: anchor)
            }
        case "getPages":
            let pages = delegate?.markdownEditorRequestsPageList(self) ?? []
            setWikiPages(pages)
        case "wikilinkPreview":
            // 注意：绝不能在当前 WKScriptMessageHandler 回调里同步调用 evaluateJavaScript，
            // 否则会与 WebKit 的消息通道死锁（曾表现为点「编辑属性」后 App 卡死）。
            // 必须延后到下一个 runloop 再执行。
            if let name = message["name"] as? String {
                let md = delegate?.markdownEditorPreviewForWikilink(self, name: name)
                let jsName = jsString(name)
                let jsMd = jsString(md ?? "")
                DispatchQueue.main.async {
                    self.webView.evaluateJavaScript("MMEditor.showPreview(\(jsName), \(jsMd))")
                }
            }
        case "getCustomTypes":
            // 宿主下发自定义类型列表，填充编辑器类型下拉（延后到主线程，规避 WKWebView 死锁）
            DispatchQueue.main.async { [weak self] in
                let list = WikiPropertySheet.loadCustomTypes()
                let arrLit: String = (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                self?.webView.evaluateJavaScript("MMEditor.setCustomTypes(\(arrLit))")
            }
        case "addCustomType":
            // 优先「内联直接新增」：entry.js 类型新增输入框回车 / 失焦时带 name 过来
            if let name = message["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { [weak self] in
                    self?.addCustomTypeInline(trimmed)
                }
            } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = "新增自定义类型"
                alert.informativeText = "输入类型名称（将共享到所有 WiKi 页的类型下拉）："
                alert.addButton(withTitle: "添加")
                alert.addButton(withTitle: "取消")
                let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                tf.placeholderString = "如：客户 / 供应商 / 竞品"
                tf.bezelStyle = .roundedBezel
                alert.accessoryView = tf
                if alert.runModal() == .alertFirstButtonReturn {
                    let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let illegal = CharacterSet(charactersIn: "():#\"'[]{}|,>%@!&*?/\\=+\n")
                    if name.rangeOfCharacter(from: illegal) != nil {
                        let a = NSAlert()
                        a.messageText = "类型名称含非法字符"
                        a.informativeText = "请勿使用括号、冒号、井号、引号、斜杠等特殊符号，以免破坏 WiKi 文件。"
                        a.addButton(withTitle: "知道了")
                        if let win = self.webView.window { a.beginSheetModal(for: win) { _ in } }
                        return
                    }
                    var list = WikiPropertySheet.loadCustomTypes()
                    if (WikiPropertySheet.allTypes + list).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        // 已存在：直接刷新并选中，不重复添加
                    } else {
                        list.append(name)
                        WikiPropertySheet.saveCustomTypes(list)
                    }
                    let arrLit: String = (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    let js = "MMEditor.setCustomTypes(\(arrLit), \(self.jsString(name)))"
                    self.webView.evaluateJavaScript(js)
                }
            }
            }
        default:
            break
        }
    }

    // 内联直接新增自定义类型：校验 → 去重 → 持久化 → 刷新下拉并选中
    private func addCustomTypeInline(_ name: String) {
        let illegal = CharacterSet(charactersIn: "():#\"'[]{}|,>%@!&*?/\\=+\n")
        guard name.rangeOfCharacter(from: illegal) == nil else {
            let a = NSAlert()
            a.messageText = "类型名称含非法字符"
            a.informativeText = "请勿使用括号、冒号、井号、引号、斜杠等特殊符号，以免破坏 WiKi 文件。"
            a.addButton(withTitle: "知道了")
            if let win = webView.window { a.beginSheetModal(for: win) { _ in } }
            return
        }
        var list = WikiPropertySheet.loadCustomTypes()
        if (WikiPropertySheet.allTypes + list).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            // 已存在：直接刷新并选中，不重复添加
        } else {
            list.append(name)
            WikiPropertySheet.saveCustomTypes(list)
        }
        let arrLit: String = (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let js = "MMEditor.setCustomTypes(\(arrLit), \(jsString(name)))"
        webView.evaluateJavaScript(js)
    }

    /// 当前编辑引擎：默认 TipTap（真·WYSIWYG）。
    /// 可在终端用 `defaults write com.weilu.meetingminutes editorEngine vditor` 回退到 Vditor。
    static var engine: String {
        let v = UserDefaults.standard.string(forKey: "editorEngine")
        return (v == "vditor") ? "vditor" : "tiptap"
    }

    /// 定位打包进 App 的 TipTap 目录（Resources/tiptap，内含 tiptap.bundle.js）。
    /// Xcode 项目的「Copy TipTap」Run Script Build Phase 会在每次构建时自动
    /// 从 ${PROJECT_DIR}/tiptap 拷过去。
    static func tiptapBaseURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("tiptap"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/tiptap"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/tiptap"),
        ]
        return candidates.compactMap { $0 }.first {
            fm.fileExists(atPath: $0.appendingPathComponent("tiptap.bundle.js").path)
        }
    }

    /// 定位打包进 App 的 Vditor 目录（Resources/vditor，内含 dist/）。
    /// 注意：vditor 整包必须放进 .app/Contents/Resources/vditor 才能被加载。
    /// Xcode 项目的「Copy Vditor」Run Script Build Phase 会在每次构建时自动
    /// 从 ${PROJECT_DIR}/vditor 拷过去；如手动 xcodebuild 缺脚本，须自己 cp。
    static func vditorBaseURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("vditor"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/vditor"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/vditor"),
        ]
        return candidates.compactMap { $0 }.first {
            fm.fileExists(atPath: $0.appendingPathComponent("dist/index.min.js").path)
        }
    }

    /// Swift String → 合法 JS 字符串字面量（用 JSON 序列化保证转义正确）。
    private func jsString(_ s: String) -> String {
        let encoded = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(data: encoded, encoding: .utf8) ?? "\"\""
    }

    private func jsBool(_ b: Bool) -> String { b ? "true" : "false" }
}

// MARK: - HTML / JS 模板（离线渲染，Vditor 由本地 dist 加载，无外部网络依赖）

fileprivate enum EditorHTML {
    static let template: String = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="%VDITOR_CDN%/dist/index.css">
    <style>
      :root { color-scheme: light dark; }
      html, body { margin: 0; padding: 0; height: 100%; }
      body {
        font-family: -apple-system, "PingFang SC", "Helvetica Neue", Arial, "Apple Color Emoji", "Apple Symbols", sans-serif;
        background: #ffffff;
      }
      /* —— 浅色 ———————————————————————————————————— */
      #fmBanner {
        max-width: 860px; margin: 14px auto 0; padding: 8px 14px;
        border: 1px solid #d8d8e0; border-radius: 8px; background: #f6f7fb;
        font-size: 12.5px; color: #555;
      }
      #fmBanner > summary { cursor: pointer; font-weight: 600; color: #2f6fdb; outline: none; user-select: none; }
      #fmBanner[open] > summary { margin-bottom: 6px; }
      .fm-table { border-collapse: collapse; width: 100%; margin-top: 4px; font-size: 13px; }
      .fm-table th, .fm-table td { padding: 5px 10px; vertical-align: top; text-align: left; border-bottom: 1px dashed #e2e3e8; }
      .fm-table th { color: #6b6b75; font-weight: 500; width: 96px; white-space: nowrap; }
      .fm-table td { color: #1c1c1e; word-break: break-word; }
      /* Vditor 容器：Obsidian 风格留白 */
      #editor { max-width: 860px; margin: 0 auto; }
      .vditor { border: none !important; box-shadow: none !important; background: transparent !important; }
      .vditor-toolbar { background: #fafafc !important; border-bottom: 1px solid #e8e8ee !important; padding: 4px 6px !important; }
      .vditor-toolbar--pin { background: #fafafc !important; }
      .vditor-reset { font-size: 15px; line-height: 1.65; padding: 16px 22px 60px !important; }
      .vditor-ir pre.vditor-reset, .vditor-wysiwyg pre.vditor-reset { background: transparent !important; }
      /* [[双链]] pill */
      .wikilink {
        color: #c6783b; font-weight: 550; border-bottom: 1px dashed #c6783b;
        cursor: pointer; border-radius: 3px; padding: 0 2px;
      }
      .wikilink:hover { background: rgba(198,120,59,0.12); }

      /* —— 深色（系统外观，跟随 prefers-color-scheme） —————————— */
      @media (prefers-color-scheme: dark) {
        body { background: #1c1c1e; }
        /* 让 vditor 容器在 dark 下吃深色背景，文字保持高对比 */
        .vditor { background: #1c1c1e !important; }
        .vditor-toolbar, .vditor-toolbar--pin { background: #2a2a2e !important; border-bottom-color: #3a3a3e !important; }
        .vditor-reset, .vditor-ir pre.vditor-reset, .vditor-wysiwyg pre.vditor-reset { background: transparent !important; color: #ebebf0 !important; }
        /* 弹窗/下拉在 dark 下：vditor 自带弹窗仍可能用白底，统一改深 */
        .vditor-hint, .vditor-panel, .vditor-dropdown-content { background: #2a2a2e !important; color: #ebebf0 !important; border-color: #3a3a3e !important; }
        /* frontmatter banner：底色更深、字色更亮、对比度提高 */
        #fmBanner { background: #24242a; border-color: #3a3a40; color: #d8d8de; }
        #fmBanner > summary { color: #74b1ff; }
        #fmBanner[open] > summary { color: #9cc8ff; }
        .fm-table th { color: #b8b8c0; }
        .fm-table td { color: #ebebf0; }
        .fm-table th, .fm-table td { border-bottom-color: #3a3a40; }
        .wikilink { color: #e0a06a; border-bottom-color: #e0a06a; }
        .wikilink:hover { background: rgba(224,160,106,0.18); }
      }
    </style>
    </head>
    <body>
    <details id="fmBanner" class="fm-banner" open><summary>笔记属性</summary><div id="fmBody"></div></details>
    <div id="editor"></div>
    <script src="%VDITOR_CDN%/dist/index.min.js"></script>
    <script>
    var VDITOR_CDN = "%VDITOR_CDN%";
    var vd = null;
    var ready = false;
    var isEditable = true;
    var pendingFrontmatter = '';   // 顶部 frontmatter 原文（保存时回贴）
    var savedMode = 'ir';

    function isDark() {
      return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    }
    function themeName() { return isDark() ? 'dark' : 'classic'; }

    // ---- frontmatter 解析（轻量，不依赖 yaml 库） ----
    function parseFrontmatter(lines){
      var fm = {}; var i = 0;
      while (i < lines.length) {
        var s = lines[i];
        var m = s.match(/^([A-Za-z0-9_\\-\\.]+):\\s*(.*)$/);
        if (!m) { i++; continue; }
        var key = m[1], val = m[2].trim();
        if (val === '') {
          var items = []; var j = i + 1;
          while (j < lines.length) {
            var ls = lines[j];
            var st = ls.match(/^\\s+-\\s+(.*)$/);
            if (st) { items.push(st[1].trim()); j++; continue; }
            break;
          }
          if (items.length) fm[key] = items;
          i = j;
        } else { fm[key] = val; i++; }
      }
      return fm;
    }
    function renderFrontmatterBanner(fm){
      if (!fm || Object.keys(fm).length === 0) return '';
      var SKIP = {'Backlinks':1, '反向链接':1, 'SuspectedAliasOf':1, 'suspected_alias_of':1};
      var rows = [];
      function addRow(label, value){
        if (value === undefined || value === null) return;
        var v = Array.isArray(value) ? value.join('、') : String(value);
        v = v.replace(/^[\\[\\(](.*)[\\]\\)]$/, '$1').replace(/^[\"“”']|[\"“”']$/g, '');
        if (!v || v === '(空)') return;
        rows.push('<tr><th>'+esc(label)+'</th><td>'+esc(v)+'</td></tr>');
      }
      // 双兼容 picker：依次尝试多个 key（中文 → PascalCase → 小写），返回第一个非空值。
      // 兼容用户后续单独改 frontmatter key 走中文（v2.2.32 路径），不再受历史 PascalCase 文件影响。
      function pick(){
        for (var i=1; i<arguments.length; i++){
          var k = arguments[i]; var v = arguments[0][k];
          if (v !== undefined && v !== null && String(v).trim() !== '') return v;
        }
        return undefined;
      }
      function pickStr(){ var v=pick.apply(null,arguments); return v===undefined?'':String(v).trim(); }
      function pickArr(){ var v=pick.apply(null,arguments); if (v===undefined) return undefined; if (Array.isArray(v)) return v; var s=String(v).trim().replace(/^[\\[\\(](.*)[\\]\\)]$/,'$1'); return s?s.split(/[,，、]/).map(function(x){return x.trim();}).filter(Boolean):[]; }
      var TYPE_LABEL = {'Person':'👤 人名','Company':'🏢 公司','Chip':'🔌 芯片','Project':'📦 项目','Topic':'📚 主题','Method':'🛠 方法'};
      var tRaw = pickStr(fm, '类型', 'Type', 'type');
      var tLabel = TYPE_LABEL[tRaw] || tRaw || '—';
      addRow('类型', tLabel);
      var cn = pickStr(fm, '规范名', 'CanonicalName', 'canonical_name', 'canonicalname');
      if (cn) addRow('规范名', cn);
      var aliasesVal = pickArr(fm, '别名', 'Aliases', 'aliases');
      if (aliasesVal && aliasesVal.length) addRow('别名', aliasesVal);
      // 按类型自适应展示专属字段（仿 Obsidian 属性面板：person / company / chip 各自一套）
      if (tRaw === 'Person') {
        addRow('中文名', pick(fm, '中文名'));
        addRow('公司',   pick(fm, '公司', 'Company', 'company'));
        addRow('职位',   pick(fm, '职位', 'Title', 'title'));
        addRow('职能范围', pick(fm, '职能范围'));
      } else if (tRaw === 'Company') {
        addRow('公司类型', pick(fm, '公司类型'));
        addRow('所属行业', pick(fm, '所属行业'));
        addRow('公司简介', pick(fm, '公司简介'));
      } else if (tRaw === 'Chip') {
        addRow('品牌',     pick(fm, '品牌'));
        addRow('具体型号', pick(fm, '具体型号'));
        addRow('类别',     pick(fm, '类别'));
        addRow('功能简述', pick(fm, '功能简述'));
        addRow('状态',     pick(fm, '状态'));
        addRow('替代料',   pick(fm, '替代料'));
      }
      var tagsRaw = pick(fm, '标签', 'Tags', 'tags');
      var tags = tagsRaw;
      if (Array.isArray(tags)) tags = tags.filter(function(x){ return x && x!=='wiki' && x.toLowerCase()!==tRaw.toLowerCase(); });
      if (tags !== undefined && (Array.isArray(tags) ? tags.length : String(tags).trim() !== '')) addRow('标签', tags);
      var upd = pick(fm, '更新时间', 'Updated', 'updated');
      if (upd !== undefined) addRow('更新时间', upd);
      // 兜底：未在上方显式列出的其它字段（含自定义类型字段）也不遗漏
      var KNOWN = ['类型','Type','type','规范名','CanonicalName','canonical_name','canonicalname','别名','Aliases','aliases','中文名','公司','Company','company','职位','Title','title','职能范围','公司类型','所属行业','公司简介','品牌','具体型号','类别','功能简述','状态','替代料','标签','Tags','tags','更新时间','Updated','updated','反向链接','Backlinks','backlinks','SuspectedAliasOf','suspected_alias_of'];
      Object.keys(fm).forEach(function(k){
        if (SKIP[k]) return;
        if (KNOWN.indexOf(k) >= 0) return;
        addRow(k, fm[k]);
      });
      if (rows.length === 0) return '';
      return '<table class="fm-table">' + rows.join('') + '</table>';
    }
    function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

    // 拆分 frontmatter / 正文
    function splitFrontmatter(md){
      var L = (md||'').replace(/\\r\\n/g,'\\n').split('\\n');
      if (L.length && L[0].trim() === '---') {
        var j = 1; while (j < L.length && L[j].trim() !== '---') j++;
        if (j < L.length) {
          var fmRaw = L.slice(0, j+1).join('\\n');
          var body = L.slice(j+1).join('\\n');
          return { fmRaw: fmRaw, body: body };
        }
      }
      return { fmRaw: '', body: md || '' };
    }
    function showBanner(md){
      var sp = splitFrontmatter(md);
      var html = '';
      if (sp.fmRaw) {
        var fm = parseFrontmatter(sp.fmRaw.split('\\n').slice(1, -1));
        html = renderFrontmatterBanner(fm);
      }
      var det = document.getElementById('fmBanner');
      if (html) { det.style.display=''; document.getElementById('fmBody').innerHTML = html; }
      else { det.style.display='none'; }
      return sp.body;
    }

    // ---- [[双链]] 装饰：把 IR/WYSIWYG 渲染后正文里的 [[x]] / [[x|alias]] 包裹成可点击 pill ----
    function getEditEl(){
      if (!vd) return null;
      if (vd.vditor && vd.vditor.ir && vd.vditor.ir.element) return vd.vditor.ir.element;
      if (vd.vditor && vd.vditor.wysiwyg && vd.vditor.wysiwyg.element) return vd.vditor.wysiwyg.element;
      if (vd.vditor && vd.vditor.sv && vd.vditor.sv.element) return vd.vditor.sv.element;
      return document.querySelector('.vditor-reset');
    }
    function decorateWikilinks(){
      try {
        var root = getEditEl(); if (!root) return;
        var re = /\\[\\[([^\\]]+?)\\]\\]/g;
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null, false);
        var nodes = []; var n;
        while ((n = walker.nextNode())) {
          if (n.parentNode && n.parentNode.closest && n.parentNode.closest('.wikilink')) continue;
          if (re.test(n.nodeValue)) nodes.push(n);
        }
        nodes.forEach(function(textNode){
          var frag = document.createDocumentFragment();
          var last = 0; var m; re.lastIndex = 0; var str = textNode.nodeValue;
          while ((m = re.exec(str))) {
            if (m.index > last) frag.appendChild(document.createTextNode(str.slice(last, m.index)));
            var seg = m[1].split('|');
            var target = seg[0].trim();
            var label = (seg[1] != null ? seg[1].trim() : target);
            var span = document.createElement('span');
            span.className = 'wikilink'; span.setAttribute('data-name', target);
            span.setAttribute('contenteditable', 'false');
            span.textContent = label;
            frag.appendChild(span);
            last = re.lastIndex;
          }
          if (last < str.length) frag.appendChild(document.createTextNode(str.slice(last)));
          if (frag.childNodes.length) textNode.parentNode.replaceChild(frag, textNode);
        });
      } catch(e) {}
    }
    var decoTimer = null;
    function scheduleDecorate(){
      if (decoTimer) clearTimeout(decoTimer);
      decoTimer = setTimeout(decorateWikilinks, 200);
    }

    // ---- 初始化 / 重建 Vditor ----
    function buildVditor(mode, value){
      savedMode = mode;
      var container = document.getElementById('editor');
      container.innerHTML = '';
      vd = new Vditor('editor', {
        cdn: VDITOR_CDN,
        mode: mode,
        lang: 'zh_CN',
        theme: themeName(),
        icon: 'material',
        cache: { enable: false },
        value: value,
        toolbarConfig: { hide: false, pin: true },
        toolbar: [
          'headings', 'bold', 'italic', 'strike', '|',
          'list', 'ordered-list', 'check', 'outdent', 'indent', '|',
          'quote', 'line', 'code', 'inline-code', '|',
          'link', 'table', '|',
          { name: 'save', tip: '保存 (⌘S)', icon: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"></path><polyline points="17 21 17 13 7 13 7 21"></polyline><polyline points="7 3 7 8 15 8"></polyline></svg>', click: function(){ requestSave(); } },
          'outline', '|', 'edit-mode', 'both', 'preview'
        ],
        outline: { enable: false, position: 'left' },
        counter: { enable: false, type: 'text' },
        preview: { theme: themeName(), actions: [], markdown: function(md){ return md; } },
        upload: false,
        fullscreen: { index: 1000 },
        after: function(){
          ready = true;
          decorateWikilinks();
        },
        input: function(){ scheduleDecorate(); },
        focus: function(){ scheduleDecorate(); },
        select: function(){ scheduleDecorate(); }
      });
    }
    function cycleMode(){
      var order = ['ir','wysiwyg','sv'];
      var cur = savedMode || 'ir';
      var next = order[(order.indexOf(cur)+1) % order.length];
      var val = vd ? vd.getValue() : '';
      buildVditor(next, val);
    }
    function setMode(mode){
      if (!vd) { savedMode = mode; return; }
      var val = vd.getValue();
      buildVditor(mode, val);
    }

    function loadMarkdown(md, editable, mode){
      isEditable = editable;
      var body = showBanner(md);
      pendingFrontmatter = splitFrontmatter(md).fmRaw;
      buildVditor(mode || 'ir', body);
    }
    function requestSave(){
      var body = vd ? vd.getValue() : '';
      var out = (pendingFrontmatter ? pendingFrontmatter + '\\n' : '') + body;
      window.webkit.messageHandlers.editorBridge.postMessage({ type: 'save', markdown: out.trimEnd() });
    }
    function setEditable(b){ isEditable = b; }

    // 点击 [[双链]] → 宿主跳转
    document.addEventListener('click', function(e){
      var link = (e.target && e.target.closest) ? e.target.closest('.wikilink') : null;
      if (link) {
        e.preventDefault();
        window.webkit.messageHandlers.editorBridge.postMessage({ type: 'wikilink', name: link.getAttribute('data-name') });
      }
    });
    // ⌘S 保存
    document.addEventListener('keydown', function(e){
      if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) { e.preventDefault(); requestSave(); }
    });
    // 跟随系统深色模式
    if (window.matchMedia) {
      window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(){
        if (vd) setMode(savedMode || 'ir');
      });
    }
    </script>
    </body>
    </html>
    """
}

// MARK: - TipTap 模板（真·WYSIWYG，Typora 风格；离线打包 tiptap.bundle.js）
fileprivate enum TipTapEditorHTML {
    static let template: String = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root { color-scheme: light dark; }
      html, body { margin: 0; padding: 0; }
      body {
        font-family: -apple-system, "PingFang SC", "Helvetica Neue", Arial, "Apple Color Emoji", "Apple Symbols", sans-serif;
        background: #ffffff; color: #1c1c1e;
      }
      /* —— 顶部页面属性 banner（与 Vditor 版一致） —————————————————— */
      #fmBanner {
        max-width: 860px; margin: 14px auto 0; padding: 8px 14px;
        border: 1px solid #d8d8e0; border-radius: 8px; background: #f6f7fb;
        font-size: 12.5px; color: #555;
      }
      #fmBanner > summary { cursor: pointer; font-weight: 600; color: #2f6fdb; outline: none; user-select: none; }
      #fmBanner[open] > summary { margin-bottom: 6px; }
      /* 顶部右侧"✏️ 编辑属性"按钮 —— 点击后通知宿主打开属性编辑面板 */
      .fm-edit-btn {
        margin-left: auto; padding: 2px 9px; font-size: 11px; font-family: inherit;
        background: #ffffff; color: #2f6fdb; border: 1px solid #c8d6f5; border-radius: 5px;
        cursor: pointer; line-height: 1.4;
      }
      .fm-edit-btn:hover { background: #eef3ff; }
      .fm-edit-btn:active { background: #d8e3fb; }
      .fm-table { border-collapse: collapse; width: 100%; margin-top: 4px; font-size: 13px; }
      .fm-table th, .fm-table td { padding: 5px 10px; vertical-align: top; text-align: left; border-bottom: 1px dashed #e2e3e8; }
      .fm-table th { color: #6b6b75; font-weight: 500; width: 96px; white-space: nowrap; }
      .fm-table td { color: #1c1c1e; word-break: break-word; }
      /* —— Obsidian 风格属性网格（只读 + 编辑通用） ——————————————
         真正标签在左、值在右同行：grid 列第一列按最长 label 自适应，
         第二列占剩余空间；长文本字段（公司简介 / 职能范围 / 功能简述等）
         跨整列单独成行，不再被压缩到右侧窄列，编辑时立即可见内容。 */
      .fm-grid { display: grid; grid-template-columns: minmax(80px, max-content) 1fr; row-gap: 2px; column-gap: 10px; margin-top: 2px; align-items: start; }
      .fm-row { display: contents; }
      .fm-row:hover { background: rgba(0,0,0,0.045); border-radius: 6px; }
      .fm-row:hover > .fm-row-label, .fm-row:hover > .fm-row-value { background: rgba(0,0,0,0.045); }
      .fm-row-label {
        display: flex; align-items: center; gap: 6px;
        color: #6b6b75; font-weight: 500; font-size: 13px; padding-top: 6px; text-align: left;
        overflow: hidden; white-space: nowrap; min-height: 26px;
      }
      .fm-icon { font-size: 13px; width: 16px; text-align: center; opacity: 0.82; flex: 0 0 auto; }
      .fm-key { overflow: hidden; text-overflow: ellipsis; max-width: 180px; }
      /* 值列默认块级：input 占满单元格，不再用 flex 嵌套，避免 width:100% 撑爆 */
      .fm-row-value { min-width: 0; padding: 3px 0; }
      .fm-row-value > input[type="text"], .fm-row-value > input[type="date"], .fm-row-value > select, .fm-row-value > textarea {
        font-family: inherit; font-size: 13px; padding: 4px 8px; border: 1px solid #e2e3e8;
        border-radius: 6px; background: #fff; color: #1c1c1e; width: 100%; box-sizing: border-box;
        display: block;
      }
      .fm-row-value input:focus, .fm-row-value select:focus, .fm-row-value textarea:focus {
        outline: none; border-color: #2f6fdb; box-shadow: 0 0 0 2px rgba(47,111,219,0.12); background: #fff;
      }
      .fm-row-value textarea { resize: vertical; min-height: 56px; line-height: 1.55; }
      .fm-select { appearance: none; -webkit-appearance: none; background: #fff; cursor: pointer; }
      /* 类型行：下拉 + ＋ 按钮 */
      .fm-type-row { display: flex; gap: 6px; align-items: center; width: 100%; }
      .fm-type-row select { flex: 1 1 auto; }
      .fm-addtype {
        flex: 0 0 auto; width: 24px; height: 24px; padding: 0; font-size: 14px; line-height: 1;
        background: #fff; color: #2f6fdb; border: 1px solid #c8d6f5; border-radius: 6px; cursor: pointer;
      }
      .fm-addtype:hover { background: #eef3ff; }
      /* 列表字段 → chips（别名 / 标签）：位于一个普通块容器，input 占满 */
      .fm-chips { display: flex; flex-wrap: wrap; gap: 4px; align-items: center; border: 1px solid #e2e3e8; padding: 4px 6px; border-radius: 6px; background: #fff; min-height: 30px; }
      .fm-chip {
        display: inline-flex; align-items: center; gap: 3px; padding: 2px 6px; max-width: 100%;
        background: #eef3ff; color: #2f6fdb; border: 1px solid #c8d6f5; border-radius: 5px;
        font-size: 12px; font-family: inherit;
      }
      .fm-chip span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .fm-chip-x { border: none; background: transparent; color: inherit; cursor: pointer; font-size: 13px; line-height: 1; padding: 0 2px; opacity: 0.65; }
      .fm-chip-x:hover { opacity: 1; }
      .fm-chip-add { flex: 1 1 60px; min-width: 60px; width: auto !important; border: 1px dashed #c8d6f5 !important; background: transparent !important; color: #6b6b75 !important; font-size: 12px; padding: 2px 4px !important; border-radius: 4px !important; }
      /* 统一「添加」输入框风格：类型新增 / 别名 / 标签新增 均使用 .fm-add-input，另起一行、全宽、虚线边框 */
      .fm-add-input {
        font-family: inherit; font-size: 13px; padding: 4px 8px; border: 1px dashed #c8d6f5;
        border-radius: 6px; background: transparent; color: #6b6b75; width: 100%; box-sizing: border-box; display: block;
      }
      .fm-add-input:focus { outline: none; border-color: #2f6fdb; background: #fff; color: #1c1c1e; }
      /* banner 内双链（反向链接 / 标量 / 长文本值）：蓝色可点击，与 banner 主色调一致 */
      #fmBanner .wikilink { color: #2f6fdb; border-bottom: 1px solid rgba(47,111,219,0.5); text-decoration: none; }
      #fmBanner .wikilink:hover { background: rgba(47,111,219,0.10); }
      /* 长文本字段：跨整列单独成行；标签独占一行、值独占一行（标签上方对齐 textarea 顶部） */
      .fm-row-long > .fm-row-label { padding-top: 4px; align-self: start; }
      .fm-row-long > .fm-row-value { grid-column: 1 / -1; padding-top: 0; padding-bottom: 4px; }
      /* 日期 / 标量 / 长文本只读 */
      .fm-date { cursor: pointer; }
      .fm-date-val, .fm-scalar-val, .fm-longtext-val { color: #1c1c1e; line-height: 1.6; }
      .fm-longtext-val { white-space: pre-wrap; }
      .fm-empty { color: #9a9aa2; }
      /* 反向链接只读区：pill 形 chip 串展示，不允许手动编辑（防破坏自动维护的双链） */
      .fm-readonly { font-size: 13px; color: #1c1c1e; line-height: 1.9; padding: 6px 0; }
      .fm-backlink-pill {
        display: inline-block; padding: 1px 8px; margin: 1px 4px 1px 0;
        background: #eef3ff; color: #2f6fdb; border: 1px solid #c8d6f5; border-radius: 4px;
        font-size: 12px; font-family: inherit;
      }
      /* 所有「添加」输入行与第 2 列（值列）对齐，与上方其余输入框保持一致宽度 */
      .fm-add-row { grid-column: 2; margin-top: 6px; }
      .fm-add-prop {
        padding: 3px 8px; font-size: 12px; font-family: inherit;
        background: transparent; color: #2f6fdb; border: none; border-radius: 6px; cursor: pointer; text-align: left;
      }
      .fm-add-prop:hover { background: rgba(47,111,219,0.08); }
      /* 新属性输入行：键占第 1 列、值占第 2 列 */
      .fm-row-new { grid-column: 1 / -1; display: grid; grid-template-columns: minmax(80px, max-content) 1fr; gap: 10px; }
      .fm-row-new .fm-newkey, .fm-row-new .fm-newval { border: 1px solid #e2e3e8 !important; background: #fff; font-size: 13px; padding: 4px 8px; border-radius: 6px; width: 100%; box-sizing: border-box; display: block; }

      /* —— 编辑器容器 —————————————————————————————————————————— */
      #editor { position: relative; max-width: 860px; margin: 0 auto; }
      .ProseMirror {
        outline: none; padding: 16px 22px 90px; font-size: 15px; line-height: 1.72;
        min-height: 60vh;
      }
      .ProseMirror > * { margin: 0 0 0.7em; }
      .ProseMirror h1 { font-size: 1.85em; font-weight: 700; margin: 0.4em 0 0.5em; line-height: 1.25; }
      .ProseMirror h2 { font-size: 1.45em; font-weight: 700; margin: 0.4em 0 0.45em; }
      .ProseMirror h3 { font-size: 1.18em; font-weight: 600; margin: 0.4em 0 0.4em; }
      .ProseMirror h4 { font-size: 1.02em; font-weight: 600; }
      .ProseMirror ul, .ProseMirror ol { padding-left: 1.5em; }
      .ProseMirror li { margin: 0.15em 0; }
      /* 任务列表（GFM - [ ] / - [x]）可勾选 checkbox */
      .ProseMirror ul[data-type="taskList"] { list-style: none; padding-left: 0.4em; }
      .ProseMirror ul[data-type="taskList"] li { display: flex; align-items: flex-start; }
      .ProseMirror ul[data-type="taskList"] li > label {
        margin-right: 0.5em; margin-top: 0.2em; flex: 0 0 auto; user-select: none;
      }
      .ProseMirror ul[data-type="taskList"] li > div { flex: 1 1 auto; min-width: 0; }
      .ProseMirror ul[data-type="taskList"] input[type="checkbox"] { width: 15px; height: 15px; cursor: pointer; }
      .ProseMirror blockquote {
        border-left: 3px solid #cfcfd6; margin-left: 0; padding: 2px 0 2px 14px; color: #555;
      }
      .ProseMirror code {
        background: #f0f0f4; border-radius: 4px; padding: 1px 5px; font-size: 0.9em;
        font-family: "SF Mono", Menlo, Consolas, monospace;
      }
      .ProseMirror pre {
        background: #f4f4f7; border-radius: 8px; padding: 12px 14px; overflow: auto;
        font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 13px;
      }
      .ProseMirror pre code { background: none; padding: 0; }
      .ProseMirror a:not(.wikilink) { color: #2f6fdb; }
      .ProseMirror table { border-collapse: collapse; width: 100%; margin: 0.5em 0; }
      .ProseMirror th, .ProseMirror td { border: 1px solid #d8d8e0; padding: 6px 10px; text-align: left; }
      .ProseMirror th { background: #f4f5f9; font-weight: 600; }
      .ProseMirror hr { border: none; border-top: 1px solid #e2e3e8; margin: 1em 0; }
      .ProseMirror img { max-width: 100%; border-radius: 6px; }
      .ProseMirror p.is-editor-empty:first-child::before {
        content: attr(data-placeholder); color: #9a9aa2; float: left; height: 0; pointer-events: none;
      }

      /* —— [[双链]] —————————————————————————————————————————————— */
      .wikilink {
        color: #5b54d6; border-bottom: 1px solid rgba(91,84,214,0.55);
        cursor: pointer; border-radius: 3px; padding: 0 2px; text-decoration: none;
      }
      .wikilink:hover { background: rgba(91,84,214,0.10); }
      .wikilink-missing {
        color: #d23b3b; border-bottom: 1px dashed #d23b3b;
      }
      .wikilink-missing:hover { background: rgba(210,59,59,0.10); }

      /* —— [[ 自动完成候选 —————————————————————————————————————— */
      .wiki-ac {
        position: absolute; z-index: 9000; background: #ffffff; border: 1px solid #d8d8e0;
        border-radius: 8px; box-shadow: 0 6px 22px rgba(0,0,0,0.14); padding: 4px;
        font-size: 12.5px; min-width: 190px; max-height: 230px; overflow-y: auto;
      }
      .wiki-ac-item { padding: 4px 10px; border-radius: 5px; color: #1c1c1e; cursor: pointer; white-space: nowrap; }
      .wiki-ac-item.active, .wiki-ac-item:hover { background: #eef0ff; }

      /* —— 悬浮预览气泡 ———————————————————————————————————————— */
      .wiki-preview {
        position: fixed; z-index: 9500; width: 340px; max-height: 264px; overflow-y: auto;
        background: #ffffff; border: 1px solid #d8d8e0; border-radius: 10px;
        box-shadow: 0 8px 30px rgba(0,0,0,0.18); padding: 12px 14px; font-size: 13px; line-height: 1.6; color: #1c1c1e;
      }
      .wiki-preview-body h1 { font-size: 1.15em; margin: 0 0 0.4em; }
      .wiki-preview-body h2 { font-size: 1.02em; margin: 0.6em 0 0.3em; }
      .wiki-preview-body p { margin: 0 0 0.5em; }
      .wiki-preview-body code { background: #f0f0f4; border-radius: 4px; padding: 1px 4px; font-size: 0.9em; }
      .wiki-preview-loading { color: #9a9aa2; }
      .wiki-preview-missing { color: #d23b3b; }
      .wiki-preview-hint { color: #9a9aa2; font-size: 11.5px; }

      /* —— 选中文字浮动工具条 —————————————————————————————————— */
      #bubbleMenu {
        display: flex; gap: 4px; background: #2a2a2e; border-radius: 8px; padding: 4px;
        box-shadow: 0 6px 22px rgba(0,0,0,0.28);
      }
      #bubbleMenu button {
        background: transparent; color: #f2f2f5; border: none; border-radius: 5px;
        padding: 4px 9px; font-size: 12px; cursor: pointer; font-family: inherit;
      }
      #bubbleMenu button:hover { background: rgba(255,255,255,0.14); }

      /* —— 深色模式 ———————————————————————————————————————————————— */
      @media (prefers-color-scheme: dark) {
        body { background: #1c1c1e; color: #ebebf0; }
        #fmBanner { background: #24242a; border-color: #3a3a40; color: #d8d8de; }
        #fmBanner > summary { color: #74b1ff; }
        .fm-table th { color: #b8b8c0; }
        .fm-table td { color: #ebebf0; }
        .fm-table th, .fm-table td { border-bottom-color: #3a3a40; }
        /* Obsidian 属性网格（深色） */
        .fm-row:hover > .fm-row-label, .fm-row:hover > .fm-row-value { background: rgba(255,255,255,0.05); }
        .fm-row-label { color: #b8b8c0; }
        .fm-row-value > input[type="text"], .fm-row-value > input[type="date"], .fm-row-value > select, .fm-row-value > textarea {
          font-family: inherit; font-size: 13px; padding: 4px 8px; border: 1px solid #4a4a52;
          border-radius: 6px; background: #2c2c32; color: #ebebf0; width: 100%; box-sizing: border-box; display: block;
        }
        .fm-row-value input:focus, .fm-row-value select:focus, .fm-row-value textarea:focus {
          outline: none; border-color: #74b1ff; box-shadow: 0 0 0 2px rgba(116,177,255,0.18); background: #2c2c32;
        }
        .fm-select { background: #2c2c32; cursor: pointer; }
        .fm-addtype { background: #2c2c32; color: #74b1ff; border: 1px solid #4a4a52; }
        .fm-addtype:hover { background: #3a3a52; }
        .fm-chip { background: rgba(116,177,255,0.15); color: #74b1ff; border: 1px solid #3a4a5e; }
        .fm-chip-add { border: 1px dashed #3a4a5e !important; background: transparent !important; color: #b8b8c0 !important; }
        .fm-add-input { border: 1px dashed #3a4a5e; background: transparent; color: #b8b8c0; width: 100%; box-sizing: border-box; display: block; padding: 4px 8px; font-family: inherit; font-size: 13px; border-radius: 6px; }
        .fm-add-input:focus { outline: none; border-color: #74b1ff; background: #2c2c32; color: #ebebf0; }
        #fmBanner .wikilink { color: #74b1ff; border-bottom-color: rgba(116,177,255,0.55); }
        #fmBanner .wikilink:hover { background: rgba(116,177,255,0.14); }
        .fm-chips { background: #2c2c32; border-color: #4a4a52; }
        .fm-date-val, .fm-scalar-val, .fm-longtext-val { color: #ebebf0; }
        .fm-readonly { font-size: 13px; color: #ebebf0; line-height: 1.9; padding: 6px 0; }
        .fm-backlink-pill {
          display: inline-block; padding: 1px 8px; margin: 1px 4px 1px 0;
          background: rgba(116,177,255,0.15); color: #74b1ff; border: 1px solid #3a4a5e; border-radius: 4px;
          font-size: 12px; font-family: inherit;
      }
      .ProseMirror code { background: #2a2a2e; }
        .ProseMirror pre { background: #26262b; }
        .ProseMirror blockquote { border-left-color: #3a3a40; color: #b8b8c0; }
        .ProseMirror th, .ProseMirror td { border-color: #3a3a3e; }
        .ProseMirror th { background: #26262b; }
        .ProseMirror hr { border-top-color: #3a3a3e; }
        .ProseMirror p.is-editor-empty:first-child::before { color: #7a7a82; }
        .wikilink { color: #b3a8ff; border-bottom-color: rgba(179,168,255,0.55); }
        .wikilink:hover { background: rgba(179,168,255,0.14); }
        .wikilink-missing { color: #ff7a7a; border-bottom-color: #ff7a7a; }
        .wiki-ac { background: #2a2a2e; border-color: #3a3a3e; color: #ebebf0; }
        .wiki-ac-item { color: #ebebf0; }
        .wiki-ac-item.active, .wiki-ac-item:hover { background: #3a3a52; }
        .wiki-preview { background: #2a2a2e; border-color: #3a3a3e; color: #ebebf0; }
        .wiki-preview-body code { background: #26262b; }
      }
    </style>
    </head>
    <body>
    <details id="fmBanner" class="fm-banner" open><summary>笔记属性</summary><div id="fmBody"></div></details>
    <div id="editor"></div>
    <script src="%TIPTAP_BASE%/tiptap.bundle.js"></script>
    <script>
      function mmIsDark(){ return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches; }
      window.addEventListener('DOMContentLoaded', function(){
        if (window.MMEditor) MMEditor.init();
        // 暴露与 Vditor 模板同名的全局函数，复用 MarkdownEditorView 现有调用约定
        window.loadMarkdown = function(md, editable, mode, autoLink){ return window.MMEditor.loadMarkdown(md, editable, mode, autoLink); };
        window.requestSave = function(){ return window.MMEditor.requestSave(); };
        window.setMode = function(m){ return window.MMEditor.setMode(m); };
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge) {
          window.webkit.messageHandlers.editorBridge.postMessage({ type: 'getPages' });
        }
      });
    </script>
    </body>
    </html>
    """
}
