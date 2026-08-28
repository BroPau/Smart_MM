//
//  MarkdownEditorView.swift
//  Meetinsight
//
//  v2.2.71：编辑器底层重写为 **TextKit 2 原生文本**（NSTextView + NSTextContentStorage
//  + NSTextLayoutManager + NSTextContainer），彻底移除 WKWebView / TipTap / Vditor，
//  不再有任何 JS 引擎与离线 bundle。
//
//  业务逻辑保持不变（与旧版公开契约完全一致）：
//  - 单一真相源 = .md 文件：frontmatter 以原生 `--- ... ---` 文本呈现并可直接编辑，
//    保存时原样回传（不再做 ```yaml 代码块 ↔ --- 的互转）。
//  - 双链关系（出链 / 入链）由宿主在打开时注入正文 `## 本页引用的页面` / `## 反向链接`
//    段，保存前在 Swift 侧剥离（stripRefsSections），不落盘、不耦合 pipeline。
//  - [[双链]] 在正文里以原生彩色文本高亮（存在的页 = 系统链接色；缺失页 = 红色），
//    点击经 mouseDown hit-test 上报宿主跳转。
//  - 自动双链（autoLink）：加载时把正文里出现的已知 Wiki 页名裸词包裹为 [[名称]]（Minutes 用）。
//  - ⌘S / Ctrl+S 触发保存；深色模式跟随系统外观（用 .textColor / .textBackgroundColor）。
//

import Cocoa

// 构建版本标记（部署校验用：rsync 前断言产物二进制含此字符串，防止误取陈旧 DerivedData 副本）。
// 用 NSLog 引用，确保该字面量被保留进二进制、不会被编译器优化掉。
fileprivate let MM_EDITOR_BUILD = "2.2.71g"

protocol MarkdownEditorViewDelegate: AnyObject {
    /// 用户点击「保存」后触发，回传当前编辑的 Markdown 源码（含 frontmatter，已剥离双链派生段）。
    func markdownEditorDidRequestSave(_ editor: MarkdownEditorView, markdown: String)
    /// 用户点击正文的 [[双链]] 时触发。anchor 为 Obsidian 式 [[Page#Heading]] 的标题锚点（可选）。
    func markdownEditorDidClickWikilink(_ editor: MarkdownEditorView, name: String, anchor: String?)
    /// 编辑器初始化时请求现有页面名列表（用于双链缺失页判定）。
    func markdownEditorRequestsPageList(_ editor: MarkdownEditorView) -> [String]
    /// 悬浮预览双链时，返回目标页正文（Markdown，已剥离 frontmatter）；页面不存在返回 nil。
    func markdownEditorPreviewForWikilink(_ editor: MarkdownEditorView, name: String) -> String?
    /// 用户点击属性编辑入口时触发（默认 no-op —— 仅 WikiViewController 关心；纪要页未实现）。
    func markdownEditorDidRequestEditProperties(_ editor: MarkdownEditorView, markdown: String)
}

/// 默认 no-op：让 markdownEditorDidRequestEditProperties 在纪要页等不需要编辑属性的场景下不必实现
extension MarkdownEditorViewDelegate {
    func markdownEditorDidRequestEditProperties(_ editor: MarkdownEditorView, markdown: String) {}
}

/// TextKit 2 原生文本视图：负责 [[双链]] 命中检测与 ⌘S 拦截。
fileprivate final class WikiTextView: NSTextView {
    weak var owner: MarkdownEditorView?

    /// 点击命中 [[双链]] 时跳转。**Typora 风格**：编辑模式下点双链也直接跳转（不要求 ⌘/Ctrl+Click），
    /// 让双链视觉上可点击；想定位光标到双链文字旁边，点击双链前后位置即可。
    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: point)
        if let link = owner?.wikilinkAt(idx) {
            NSLog("[Meetinsight/wiki] wikilink click: name=%@ anchor=%@ at idx=%d", link.name, link.anchor ?? "<nil>", idx)
            owner?.delegate?.markdownEditorDidClickWikilink(owner!, name: link.name, anchor: link.anchor)
            return
        }
        super.mouseDown(with: event)
    }

    /// ⌘S / Ctrl+S 触发保存（旧 JS 版也是编辑器内部自己处理，菜单无 save 项）。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)),
           let chars = event.charactersIgnoringModifiers,
           chars == "s" {
            owner?.requestSave()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class MarkdownEditorView: NSView, NSTextViewDelegate {

    weak var delegate: MarkdownEditorViewDelegate?

    // MARK: - TextKit 2 栈
    private let contentStorage = NSTextContentStorage()
    private var textView: WikiTextView!

    // MARK: - 状态
    /// v2.2.65：当前页是否有未保存改动（切页自动保存用）。
    var isDirty: Bool = false
    /// 加载期间抑制 dirty 标记（避免把「载入新页 / 重算高亮」误判为用户编辑）。
    private var suppressDirty: Bool = false
    /// 当前页名（供 [[#Heading]] 同页锚点兜底）。
    private var currentPageName: String = ""
    /// 已知 Wiki 页名（小写集合），用于缺失页判定与自动双链。
    private var wikiPageNames: Set<String> = []
    /// 自动双链目标名（仅 Wiki 页名），加载纪要时把裸词包裹为 [[名称]]。
    private var autoLinkNames: [String] = []
    /// v2.2.71b+：markdown 样式重算的防抖定时器（textDidChange 后 300ms 内合并多次输入）。
    private var styleDebounceTimer: Timer?

    // MARK: - 初始化
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]

        // —— TextKit 2：contentStorage → layoutManager → textContainer ——
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.textContainer = textContainer

        let tv = WikiTextView(frame: .zero, textContainer: textContainer)
        tv.owner = self
        tv.delegate = self
        // NSTextView 作为 NSScrollView.documentView 必须走 autoresizingMask（不是 constraints）：
        //   - translatesAutoresizingMaskIntoConstraints = false 会让 autoresizingMask 失效
        //   - 没设 autoresizingMask → textView.frame 永远 .zero → documentView 零尺寸 → 整片空白
        // 标准模式：autoresizingMask = [.width]（宽度跟随 scrollView.contentSize，高度由 isVerticallyResizable + 内容决定）
        tv.autoresizingMask = [.width]
        // 关键：必须 isRichText = true，NSTextView 才会渲染 textStorage 上的字符属性
        // （字体/颜色/段落样式）。设 false 时视图进入「纯文本模式」，忽略所有 attribute，
        // 导致 markdown 样式（标题/粗体/双链颜色）全部不上屏——这是前几轮「有显示但不渲染」的根因。
        tv.isRichText = true
        tv.isEditable = false
        tv.isSelectable = true
        tv.allowsUndo = true
        // v2.2.71b+：正文用系统字体（更贴 Typora），代码/代码块仍用等宽字体（在 recomputeMarkdownStyles 里覆盖）。
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = CGSize(width: 0, height: 0)
        tv.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 24, height: 18)
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        self.textView = tv

        scrollView.documentView = tv
        // 首次挂载时 scrollView 还未 layout，documentView.frame 仍是 .zero；显式给一个初始高度，
        // 避免 load(markdown:) 后 textStorage 有内容但可视区是 0 高、看起来全空。后续 layout 会被
        // autoresizingMask + isVerticallyResizable 接管，按内容自适应。
        tv.frame = NSRect(x: 0, y: 0, width: max(scrollView.contentSize.width, 200), height: 200)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        NSLog("Meetinsight TextKit2 editor build %@", MM_EDITOR_BUILD)
    }

    // MARK: - 公开 API（契约与旧版一致）

    /// 载入并渲染 Markdown（原生文本，含 --- frontmatter 与 ## 双链派生段）。
    /// editable=false 时预览区不可编辑（如搜索结果 / 错误提示）。
    /// autoLink=true 时（仅纪要页单人纪要用），加载时会把正文里出现的已知 Wiki 页名裸词自动包裹为 [[名称]]。
    func load(markdown: String, editable: Bool = true, autoLink: Bool = false, pageName: String = "") {
        currentPageName = pageName
        let finalMd = autoLink ? applyAutoLink(to: markdown, names: autoLinkNames) : markdown
        suppressDirty = true
        textView.isEditable = editable
        textView.string = finalMd
        recomputeMarkdownStyles()
        suppressDirty = false
        isDirty = false
    }

    /// 触发保存：读取当前编辑内容（含 frontmatter）并回传宿主，保存前在 Swift 侧剥离双链派生段。
    func requestSave() {
        isDirty = false
        let md = stripRefsSections(textView.string)
        delegate?.markdownEditorDidRequestSave(self, markdown: md)
    }

    /// 推送现有页面名列表（含别名），供双链缺失页判定 + 自动双链。
    func setWikiPages(_ names: [String]) {
        wikiPageNames = Set(names.map { $0.lowercased() })
        recomputeMarkdownStyles()
    }

    /// 推送「自动双链」目标名列表（仅 Wiki 页名）；加载纪要时把正文里出现的裸词包裹为 [[名称]]。
    func setAutoLinkNames(_ names: [String]) {
        autoLinkNames = names
    }

    /// 跳转到 Wiki 页内某标题锚点（Obsidian 式 [[Page#Heading]]）；无匹配标题时静默忽略。
    func scrollToAnchor(_ anchor: String) {
        let a = anchor.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        let full = textView.string as NSString
        let pattern = "^(#{1,6})\\s+" + NSRegularExpression.escapedPattern(for: a) + "$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
              let m = re.firstMatch(in: full as String, range: NSRange(location: 0, length: full.length)) else { return }
        textView.scrollRangeToVisible(m.range)
        textView.setSelectedRange(m.range)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !suppressDirty else { return }
        isDirty = true
        // 防抖 300ms 后重算 markdown 样式（标题/粗体/斜体/代码/双链着色），
        // 避免逐字符重算破坏 typingAttributes / 光标位置 / 输入流畅度。
        scheduleStyleUpdate()
    }

    private func scheduleStyleUpdate() {
        styleDebounceTimer?.invalidate()
        styleDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.recomputeMarkdownStyles()
        }
    }

    // MARK: - 内部：双链命中检测

    /// 给定字符索引，判断其是否落在某个 [[双链]] 范围内，返回 (page, anchor)。
    fileprivate func wikilinkAt(_ idx: Int) -> (name: String, anchor: String?)? {
        let full = textView.string as NSString
        guard idx >= 0, idx <= full.length else { return nil }
        let range = NSRange(location: 0, length: full.length)
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]+?)(?:\|([^\[\]\n]+?))?\]\]"#) else { return nil }
        for m in re.matches(in: full as String, range: range) {
            // 点击点（idx 或 idx-1）落在链接范围内即视为命中
            if NSLocationInRange(idx, m.range) || NSLocationInRange(max(0, idx - 1), m.range) {
                let inner = (full.substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespaces)
                var page = inner
                var anchor: String? = nil
                if page.hasPrefix("#") {
                    // 同页锚点 [[#Heading]]：page 用当前页名兜底，anchor = 标题
                    anchor = String(page.dropFirst()).trimmingCharacters(in: .whitespaces)
                    page = currentPageName
                } else if let h = page.firstIndex(of: "#") {
                    anchor = String(page[page.index(after: h)...]).trimmingCharacters(in: .whitespaces)
                    page = String(page[..<h])
                }
                return (name: page, anchor: anchor)
            }
        }
        return nil
    }

    // MARK: - 内部：Markdown 样式渲染（Typora 风格视觉样式）

    /// 基础字体（正文 / 非代码）。代码 / 代码块用 monospacedSystemFont 覆盖。
    private let bodyFont = NSFont.systemFont(ofSize: 14)
    /// 代码字体（行内 `code` 与围栏代码块共用）。
    private let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    /// 代码背景色（弱对比，沿用系统色，跟随深色模式）。
    private let codeBg = NSColor.controlBackgroundColor

    /// 全量重算 markdown 样式。
    ///
    /// v2.2.71g：放弃 v2.2.71f「本地 NSMutableAttributedString + setAttributedString 写回」——
    /// 验证发现 setAttributedString 后 `NSTextContentStorage` 没把 attribute 透传到 `NSTextLayoutManager`，
    /// 表现是 frontmatter 的 foregroundColor/键名 font 渲染 OK，但正文的 .font/.paragraphStyle 完全不显示。
    /// 现改为最朴素的 v2.2.71c 路径：**直接对 `textStorage` 在 `beginEditing()`/`endEditing()` 之间调 addAttribute**。
    /// 这次能 work 是因为两个前置条件都已 OK：
    ///   1. `isRichText = true`（v2.2.71e 已设，纯文本模式会忽略全部 attribute）
    ///   2. `applyHeaderStyles` 等用 `NSFont.systemFont(ofSize:weight:)`（v2.2.71e 改对，NSFontManager.convert
    ///      在 systemFont 上不可靠）
    ///
    /// 叠加顺序（后写覆盖先写）：
    /// 1. reset → 全部回到 bodyFont + textColor + 默认段落样式
    /// 2. frontmatter 段（灰色背景 + 键名加粗 + 主题色）
    /// 3. 段落级（blockquote / list）
    /// 4. 标题行
    /// 5. 围栏代码 / 行内代码
    /// 6. 粗体 / 斜体
    /// 7. [[双链]] 着色（最后）
    private func recomputeMarkdownStyles() {
        guard let storage = textView.textStorage else { return }
        let raw = storage.string
        let rawLen = (raw as NSString).length
        guard rawLen > 0 else { return }

        suppressDirty = true
        defer { suppressDirty = false }

        let full = raw as NSString
        let fullRange = NSRange(location: 0, length: full.length)

        NSLog("[Meetinsight/md] recompute start, len=%d", full.length)

        // 直接对 storage 做 edit；begin/end 包裹确保 NSTextContentStorage 把
        // attribute 透传给 NSTextLayoutManager → 实际渲染层。
        storage.beginEditing()

        // 1. 重置：整段回到正文基础（font + foregroundColor + 段落样式）。
        // 仍然用 setAttributes：因为这次是"reset 整段"，不是"替换 storage",
        // 不会触发 v2.2.71f 的 attribute 透传 bug。
        let defaultPara = NSMutableParagraphStyle()
        storage.setAttributes(
            [
                .font: bodyFont,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: defaultPara
            ],
            range: fullRange
        )

        // 2-7. 顺序叠加各 markdown 样式，全部直接写到 storage。
        applyFrontmatterStyles(in: storage, full: full)
        applyBlockquoteStyles(in: storage, full: full)
        applyListStyles(in: storage, full: full)
        applyHeaderStyles(in: storage, full: full)
        applyCodeBlockStyles(in: storage, full: full)
        applyInlineCodeStyles(in: storage, full: full)
        applyBoldStyles(in: storage, full: full)
        applyItalicStyles(in: storage, full: full)
        applyWikilinkColors(in: storage, full: full)

        let sampleFont = (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        let hasPara = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) != nil
        NSLog("[Meetinsight/md] recompute done, font@0=%.1fpt para@0=%@",
              Double(sampleFont), hasPara ? "yes" : "no")

        storage.endEditing()
    }

    /// frontmatter 段（顶部 `--- ... ---`）：整段背景淡化 + 键名加粗 + 主题色。
    /// 若文件无 frontmatter（开头不是 `---`），则不做任何修改。
    /// 接收 `NSTextStorage`（NSMutableAttributedString 子类）——所有 attribute 直接写到 storage。
    /// `storage.addAttribute` 在 begin/end editing 之间会被 NSTextContentStorage 正确透传。
    private func applyFrontmatterStyles(in storage: NSTextStorage, full: NSString) {
        let str = full as String
        let lines = str.components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return }
        var secondDashLine = -1
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                secondDashLine = i
                break
            }
        }
        guard secondDashLine > 0 else { return }
        // 计算 frontmatter 段的 NSRange（包含末尾 `---` 与换行）
        var loc = 0
        for i in 0..<secondDashLine {
            loc += (lines[i] as NSString).length + 1  // +1 for newline
        }
        let fmEndLoc = loc + (lines[secondDashLine] as NSString).length
        let fmRange = NSRange(location: 0, length: fmEndLoc)

        // 整段背景弱化（区分 frontmatter 块 vs 正文）
        let fmBg = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        storage.addAttribute(.backgroundColor, value: fmBg, range: fmRange)

        // 键名加粗 + 主题色（Capture group 1 是键名）
        guard let re = try? NSRegularExpression(pattern: #"^([A-Za-z_\u4e00-\u9fa5][A-Za-z0-9_\u4e00-\u9fa5]*)\s*:"#, options: .anchorsMatchLines) else { return }
        let matches = re.matches(in: str, range: NSRange(location: 0, length: fmEndLoc))
        // v2.2.71e+：NSFontDescriptor.withSymbolicTraits 在 macOS 12+ 返回 non-optional，
        // 因此不再需要 if let，直接用 let。
        let boldDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.bold)
        let keyFont = NSFont(descriptor: boldDescriptor, size: bodyFont.pointSize) ?? bodyFont
        let accent = NSColor.controlAccentColor
        for m in matches {
            // 跳过顶部的 `---` 行
            if m.range.location < (lines[0] as NSString).length + 1 { continue }
            // 跳过结尾的 `---` 行
            if m.range.location >= loc { continue }
            storage.addAttribute(.font, value: keyFont, range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
    }

    // MARK: - 样式辅助

    /// 标题行：1~6 个 `#` + 空格开头，**整行**用对应字号 + bold。
    private func applyHeaderStyles(in storage: NSTextStorage, full: NSString) {
        guard let re = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#, options: .anchorsMatchLines) else { return }
        let matches = re.matches(in: full as String, range: NSRange(location: 0, length: full.length))
        NSLog("[Meetinsight/md] headers: %d match(es)", matches.count)
        for m in matches {
            let hashes = full.substring(with: m.range(at: 1))
            let size: CGFloat
            switch hashes.count {
            case 1: size = 24
            case 2: size = 20
            case 3: size = 17
            case 4: size = 15
            case 5: size = 14
            default: size = 13
            }
            let headerFont = NSFont.systemFont(ofSize: size, weight: .bold)
            // 整行应用（保留 ## 符号可见，但与正文同字体大小，视觉上是「带 # 的标题」）
            storage.addAttribute(.font, value: headerFont, range: m.range)
        }
    }

    /// 粗体 `**text**`：在当前字体上叠加 bold trait（保留标题/正文字号）。
    /// 用 `fontDescriptor.withSymbolicTraits(.bold)` 重建字体（对 systemFont 同样可靠——
    /// NSFontManager 在系统字体上转换有时不变 trait，descriptor 重建显式合成新 font）。
    private func applyBoldStyles(in storage: NSTextStorage, full: NSString) {
        guard let re = try? NSRegularExpression(pattern: #"\*\*([^\*\n]+?)\*\*"#) else { return }
        let matches = re.matches(in: full as String, range: NSRange(location: 0, length: full.length))
        NSLog("[Meetinsight/md] bold: %d match(es)", matches.count)
        for m in matches {
            let r = m.range(at: 1)
            let current = (storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? bodyFont
            var merged: NSFontDescriptor.SymbolicTraits = .bold
            if current.fontDescriptor.symbolicTraits.contains(.italic) { merged.insert(.italic) }
            // v2.2.71e+：withSymbolicTraits 返回 non-optional。
            let descriptor = current.fontDescriptor.withSymbolicTraits(merged)
            if let f = NSFont(descriptor: descriptor, size: current.pointSize) {
                storage.addAttribute(.font, value: f, range: r)
            }
        }
    }

    /// 斜体 `*text*`：用 lookbehind/lookahead 避免误匹配 `**bold**` 里的 `*`。
    private func applyItalicStyles(in storage: NSTextStorage, full: NSString) {
        guard let re = try? NSRegularExpression(pattern: #"(?<!\*)\*([^\*\n]+?)\*(?!\*)"#) else { return }
        let matches = re.matches(in: full as String, range: NSRange(location: 0, length: full.length))
        for m in matches {
            let r = m.range(at: 1)
            let current = (storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? bodyFont
            var merged: NSFontDescriptor.SymbolicTraits = .italic
            if current.fontDescriptor.symbolicTraits.contains(.bold) { merged.insert(.bold) }
            let descriptor = current.fontDescriptor.withSymbolicTraits(merged)
            if let f = NSFont(descriptor: descriptor, size: current.pointSize) {
                storage.addAttribute(.font, value: f, range: r)
            }
        }
    }

    /// 行内代码：`` `text` ``
    private func applyInlineCodeStyles(in storage: NSTextStorage, full: NSString) {
        guard let re = try? NSRegularExpression(pattern: #"`([^`\n]+?)`"#) else { return }
        let matches = re.matches(in: full as String, range: NSRange(location: 0, length: full.length))
        for m in matches {
            let r = m.range(at: 1)
            storage.addAttributes([.font: codeFont, .backgroundColor: codeBg], range: r)
        }
    }

    /// 围栏代码块：```...```（多行）。
    private func applyCodeBlockStyles(in storage: NSTextStorage, full: NSString) {
        guard let re = try? NSRegularExpression(pattern: #"```[\s\S]*?```"#, options: []) else { return }
        let matches = re.matches(in: full as String, range: NSRange(location: 0, length: full.length))
        for m in matches {
            storage.addAttributes([.font: codeFont, .backgroundColor: codeBg], range: m.range)
        }
    }

    /// 列表：`- ` / `* ` / `+ ` / `1. ` 开头，整行段落加左侧缩进。
    private func applyListStyles(in storage: NSTextStorage, full: NSString) {
        guard let re = try? NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+\.)\s+"#, options: .anchorsMatchLines) else { return }
        let str = full as String
        let matches = re.matches(in: str, range: NSRange(location: 0, length: full.length))
        NSLog("[Meetinsight/md] list: %d match(es)", matches.count)
        for m in matches {
            guard let swiftRange = Range(m.range, in: str) else { continue }
            let lineSwiftRange = str.lineRange(for: swiftRange)
            let lineNSRange = NSRange(lineSwiftRange, in: str)
            let p = NSMutableParagraphStyle()
            p.headIndent = 20
            p.firstLineHeadIndent = 0
            storage.addAttribute(.paragraphStyle, value: p, range: lineNSRange)
        }
    }

    /// 引用：`> ` 开头，整行段落加左侧缩进 + 斜体。
    private func applyBlockquoteStyles(in storage: NSTextStorage, full: NSString) {
        guard let re = try? NSRegularExpression(pattern: #"^>\s+"#, options: .anchorsMatchLines) else { return }
        let str = full as String
        let matches = re.matches(in: str, range: NSRange(location: 0, length: full.length))
        for m in matches {
            guard let swiftRange = Range(m.range, in: str) else { continue }
            let lineSwiftRange = str.lineRange(for: swiftRange)
            let lineNSRange = NSRange(lineSwiftRange, in: str)
            let p = NSMutableParagraphStyle()
            p.headIndent = 20
            p.firstLineHeadIndent = 20
            storage.addAttribute(.paragraphStyle, value: p, range: lineNSRange)
        }
    }

    /// [[双链]] 着色：存在 = 链接蓝；缺失 = 系统红。**最后应用**，避免被其他样式覆盖。
    private func applyWikilinkColors(in storage: NSTextStorage, full: NSString) {
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]+?)(?:\|([^\[\]\n]+?))?\]\]"#) else { return }
        let matches = re.matches(in: full as String, range: NSRange(location: 0, length: full.length))
        for m in matches {
            let inner = (full.substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespaces)
            var page = inner
            if page.hasPrefix("#") {
                page = currentPageName
            } else if let h = page.firstIndex(of: "#") {
                page = String(page[..<h])
            }
            let missing = page.isEmpty ? false : !wikiPageNames.contains(page.lowercased())
            let color: NSColor = missing ? .systemRed : .linkColor
            storage.addAttribute(.foregroundColor, value: color, range: m.range)
        }
    }

    // MARK: - 内部：保存前剥离双链派生段

    /// 剥离由宿主注入的派生段：## 反向链接 / ## 本页引用的页面（命中即跳到下一个标题或文末）。
    private func stripRefsSections(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false
        let headingRe = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#)
        for line in lines {
            let ns = line as NSString
            if let re = headingRe,
               let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let title = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if title == "反向链接" || title == "本页引用的页面" {
                    skipping = true
                    continue
                }
                skipping = false
            }
            if !skipping { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 内部：自动双链（移植自旧 JS 的 autoLinkWiki）

    private func applyAutoLink(to md: String, names: [String]) -> String {
        guard !names.isEmpty else { return md }
        let sorted = names.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let lines = md.components(separatedBy: "\n")
        var inFence = false
        var out: [String] = []
        for line in lines {
            if line.range(of: #"^\s*(```|~~~)"#, options: .regularExpression) != nil {
                inFence.toggle()
                out.append(line)
                continue
            }
            if inFence { out.append(line); continue }
            out.append(autoLinkLine(line, names: sorted))
        }
        return out.joined(separator: "\n")
    }

    private func autoLinkLine(_ line: String, names: [String]) -> String {
        var protected: [String] = []
        var s = line
        func protect(_ m: String) -> String {
            protected.append(m)
            return "\u{0}\(protected.count - 1)\u{0}"
        }
        // 保护：行内代码、标准链接、已有双链，避免重复包裹
        s = replaceMatches(pattern: #"`[^`]*`"#, in: s) { protect($0) }
        s = replaceMatches(pattern: #"\[[^\]]*\]\([^)]*\)"#, in: s) { protect($0) }
        s = replaceMatches(pattern: #"\[\[[^\]]*\]\]"#, in: s) { protect($0) }
        // 包裹已知名称（长名优先）；每轮重新保护生成的 [[名称]]，避免更短名称二次包裹
        for name in names {
            let esc = NSRegularExpression.escapedPattern(for: name)
            s = replaceMatches(pattern: esc, in: s) { _ in "[[\(name)]]" }
            s = replaceMatches(pattern: #"\[\[[^\]]*\]\]"#, in: s) { protect($0) }
        }
        // 还原被保护的片段
        s = replaceMatches(pattern: #"\x00(\d+)\x00"#, in: s) { m in
            let digits = m.replacingOccurrences(of: "\u{0}", with: "")
            if let n = Int(digits), n < protected.count { return protected[n] }
            return m
        }
        return s
    }

    /// 通用正则替换（block 接收匹配原文，返回替换文本）。
    private func replaceMatches(pattern: String, in string: String, using block: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return string }
        let ns = string as NSString
        let matches = re.matches(in: string, range: NSRange(location: 0, length: ns.length))
        var result = ""
        var last = 0
        for m in matches {
            let r = m.range
            if r.location > last {
                result += ns.substring(with: NSRange(location: last, length: r.location - last))
            }
            result += block(ns.substring(with: r))
            last = r.location + r.length
        }
        if last < ns.length {
            result += ns.substring(from: last)
        }
        return result
    }
}
