//
//  WikiPropertySheet.swift
//  Meetinsight
//
//  「新增 / 编辑 WiKi 页」属性表单 —— 仿 Obsidian 笔记属性面板：
//    通用字段：类型 / 规范名 / 别名 / 标签 / 更新 / 反向链接
//    按 type 动态显示对应专属字段（其它类型的字段自动折叠，零空白）：
//      Person  → 中文名 / 公司 / 职位 / 职能范围
//      Company → 公司类型 / 所属行业 / 公司简介
//      Chip    → 品牌 / 具体型号 / 类别 / 功能简述 / 状态 / 替代料
//    字段顺序与 Obsidian 面板一致；类型值统一 TitleCase；所有标签中文显示。
//  独立 NSWindow 模态弹窗，自带 type 切换时字段显隐、aliases/tags 标签 pill 增删。
//  自定义类型（持久化到 custom_types.json）只会显示通用字段。
//
//  v2.2.33 升级：
//   - 「功能简述」「公司简介」「反向链接」等多行字段高度统一为 24px（与其他单行输入框纵向对齐），
//     内部 NSTextView 嵌在 NSScrollView 里，可纵向滚动输入多行；
//   - 「类型」栏宽度撑满 outerStack-100，高度统一 24px（与其他输入栏视觉一致）；
//   - 「别名」「标签」TagFieldView 改造：pill 行在上、「+ 添加」独立行在下；
//   - 所有文本字段（14 个 NSTextField + 3 个 NSTextView）替换为 WikiLinkTextField / WikiLinkTextView，
//     实时扫描 `[[Page]]` / `[[Page|alias]]` / `[[Page#anchor]]`，渲染为蓝色超链接+下划线，
//     点击跳转通知 WikiLinkRouter.openWikiPage；
//   - 「新增自定义类型」NSAlert 输入框不替换（一次性 dialog，无需双链渲染）。
//

import Cocoa

// MARK: - 全局双链跳转路由（v2.2.33）
//
// 任何地方点 [[Page]] 都通过 Notification 派发到 WikiViewController.openWikiPageResolved(name,anchor)。
// WikiPropertySheet 与 MarkdownEditorView（已存在）共用同一条跳转通道，避免重复实现。
extension Notification.Name {
    static let openWikiPage = Notification.Name("com.weilu.meetinsight.openWikiPage")
}

/// 派发「打开 Wiki 页」请求。订阅方由 WikiViewController 注入（见 WikiViewController.viewDidLoad）。
enum WikiLinkRouter {
    static func open(name: String, anchor: String? = nil) {
        var userInfo: [String: Any] = ["name": name]
        if let a = anchor, !a.isEmpty { userInfo["anchor"] = a }
        NotificationCenter.default.post(name: .openWikiPage, object: nil, userInfo: userInfo)
    }
}

/// 把 `meetinsight://open-wiki/Page#Anchor` 链接解析为 wiki 页跳转（统一供点击路由复用）。
/// 返回 true 表示已处理（消费点击，不再交给系统当成 URL 打开）。
fileprivate func handleMeetinsightLink(_ url: URL) -> Bool {
    guard url.scheme == "meetinsight" else { return false }
    var page: String
    if url.host == "open-wiki" {
        page = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    } else {
        page = url.absoluteString.replacingOccurrences(of: "meetinsight://open-wiki/", with: "")
    }
    // 中文页名在 link 里是百分号编码，必须解码才能匹配到真实页名
    if let decoded = page.removingPercentEncoding { page = decoded }
    page = page.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    // 防御：path 里可能残留 #Heading 段
    if let hash = page.range(of: "#") {
        let a = String(page[hash.upperBound...])
        page = String(page[..<hash.lowerBound])
        if !a.isEmpty { WikiLinkRouter.open(name: page, anchor: a.removingPercentEncoding ?? a); return true }
    }
    var anchor: String? = nil
    if let frag = url.fragment, !frag.isEmpty { anchor = frag.removingPercentEncoding ?? frag }
    if !page.isEmpty {
        WikiLinkRouter.open(name: page, anchor: anchor)
        return true
    }
    return false
}

// MARK: - WikiPageSpec（v2.2.33 未变）

/// 提交到 pipeline.py 的全量 spec。所有字段都存在，未填者为空字符串。
struct WikiPageSpec {
    var name: String                       // canonical_name
    var type: String                       // Person / Company / Chip …（首字母大写）
    var aliases: [String]
    var tags: [String]
    var updated: String                    // YYYY-MM-DD，空则用今日
    var backlinks: [String]                // [[双链]] 列表

    // person 专属
    var chineseName: String                // 中文名
    var company: String
    var jobTitle: String                   // frontmatter `title`
    var role: String                       // frontmatter `职能范围`

    // company 专属
    var companyType: String                // 公司类型
    var industry: String                   // 所属行业
    var companyIntro: String               // 公司简介

    // chip 专属
    var brand: String                      // 品牌
    var model: String                      // 具体型号
    var category: String                   // 类别
    var functionDesc: String               // 功能简述
    var status: String                     // 状态
    var replacement: String                // 替代料
}

extension WikiPageSpec {
    /// 兜底默认值（与 pipeline.py PLACEHOLDER 保持一致）。
    static let placeholder = "（待补全）"

    /// 类型 token 集合（首字母大写），用于 tags 同步时剔除旧类型标签。
    static let typeTokens = ["Person", "Company", "Chip", "Project", "Topic", "Method"]

    func asDictForPython() -> [String: Any] {
        // v2.2.63：改用英文 key（type/canonical_name/aliases/tags/backlinks/...）以匹配 pipeline.py 的 spec 键契约，
        //     此前用中文 key（"类型"/"规范名"/...）会让 spec.get("type") 永远 None → "type 必须是 ...，收到：空"。
        //     值仍保持 PascalCase（Person/Company/Chip/...），与磁盘 YAML `type: Person`、UI picker、错误消息一致。
        //     中文 key 同步发送作为兜底（pipeline v2.2.63 起容错，同时接受 type/类型 等中英键）。
        var d: [String: Any] = [
            "type": type,
            "类型": type,
            "canonical_name": name,
            "规范名": name,
            "aliases": aliases,
            "别名": aliases,
            "tags": tags,
            "标签": tags,
            "updated": updated,
            "更新时间": updated,
            "backlinks": backlinks,
            "反向链接": backlinks
        ]
        switch type {
        case "Person":
            d["中文名"]    = chineseName
            d["公司"]      = company
            d["company"]  = company   // pipeline 读英文键
            d["职位"]      = jobTitle
            d["title"]    = jobTitle  // pipeline 读英文键
            d["职能范围"]  = role
        case "Company":
            d["公司类型"]  = companyType
            d["所属行业"]  = industry
            d["公司简介"]  = companyIntro
        case "Chip":
            d["品牌"]      = brand
            d["具体型号"]  = model
            d["类别"]      = category
            d["功能简述"]  = functionDesc
            d["状态"]      = status
            d["替代料"]    = replacement
        default: break  // Project/Topic/Method 无专属字段
        }
        return d
    }
}

// MARK: - WikiLinkTextField（单行文本字段）
//
// 单行文本输入控件，高度 24px。直接继承 NSTextField。
// v2.2.44：去掉三层 NSView→NSScrollView→NSTextView 包装（那是「点不到/回不去/死锁」根因）。
// v2.2.45：试过 isBezeled=false + 自绘 layer 边框 + 自定义 cell —— 实测 NSTextField 的
//          cell 绘制会把背景覆盖在 layer 边框之上 → 无圆角框；且 isBezeled=false 默认顶对齐
//          → 光标不居中。
// v2.2.46：改回系统原生 roundedBezel —— 自带圆角边框 + 文本垂直居中，最可靠，外观与
//          会议纪要文本框一致。单行字段不含 `[[Page]]`，双链渲染集中在多行 WikiLinkTextView。
final class WikiLinkTextField: NSTextField, NSTextFieldDelegate {
    var onChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // v2.2.46：系统原生 roundedBezel（自带圆角边框 + 文本垂直居中）。
        self.isBordered = true
        self.bezelStyle = .roundedBezel
        self.font = .systemFont(ofSize: 12)
        self.textColor = .labelColor
        self.delegate = self
        self.lineBreakMode = .byTruncatingTail
        self.usesSingleLineMode = true
        self.cell?.wraps = false
        self.cell?.isScrollable = true
        // wantsLayer 仅用于在 markInvalid() 时叠红色边框（原生 bezel 之上）。
        self.wantsLayer = true
        // 固定 24px 高（与 NSTextField 等同，纵向与多行字段对齐）。
        self.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { nil }

    /// 设置文本（保留原有调用方 API：setStringValue(_:)）。
    func setStringValue(_ s: String) { self.stringValue = s }

    // MARK: NSControlTextEditingDelegate
    func controlTextDidChange(_ obj: Notification) { onChange?() }
    func controlTextDidEndEditing(_ obj: Notification) { onChange?() }

    /// 校验失败：在原生 bezel 之上叠红色边框（之后用户编辑会由 onChange 调 clearInvalid 复位）。
    func markInvalid() {
        self.layer?.borderColor = NSColor.systemRed.cgColor
        self.layer?.borderWidth = 1.5
    }
    /// 复位：去掉叠加边框，回到原生 roundedBezel 外观。
    func clearInvalid() {
        self.layer?.borderWidth = 0
    }
}

// MARK: - WikiLinkTextView（v2.2.44 重写：NSScrollView 直接包 NSTextView，去掉外层 NSView）
//
// 多行版本，高度 24px（与 v2.2.33 一致，纵向滚动）。直接继承 NSScrollView，
// documentView 为 NSTextView（**无外层 NSView 包装**），从根上修复 hit-test / first-responder
// 链断裂（这正是「点不到 / 回不去 / 某些框死锁」的真正根因）。
// 同样的 `[[Page]]` 高亮 + 点击跳转（clickedOnLink → WikiLinkRouter.open）。
final class WikiLinkTextView: NSScrollView, NSTextViewDelegate {
    let textView: NSTextView
    var onChange: (() -> Void)?
    var stringValue: String { textView.string }

    func setStringValue(_ s: String) {
        textView.string = s
        highlightWikiLinks()
    }

    override init(frame frameRect: NSRect) {
        textView = NSTextView()
        super.init(frame: frameRect)

        // 1) textView 必须先正确设置 sizing，再作为 documentView 挂到 scrollView。
        //    默认 NSTextView() 创建时 frame 为 0×0，缺少 minSize/maxSize 与 containerSize
        //    会让 scrollView 的 contentView 不知道文档视图该多大 → 在 NSStackView 中作为
        //    行字段时，整体高度/可见面积异常，导致字段边框与内容不可见（v2.2.44 回归）。
        textView.minSize = NSSize(width: 0, height: 24)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: 11)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        textView.backgroundColor = .textBackgroundColor

        // 2) ScrollView 配置（无 bezel；圆角 + 边框靠外层 layer 自绘）
        self.translatesAutoresizingMaskIntoConstraints = false
        self.hasVerticalScroller = true
        self.hasHorizontalScroller = false
        self.borderType = .noBorder
        self.drawsBackground = false
        self.autohidesScrollers = true
        // NSTextView 默认 textContainer.widthTracksTextView=true + 高度随内容；
        // 配合 .width 自动调整，containerSize 不用手设，挂上 documentView 后会自动撑开。
        self.documentView = textView

        // 3) 圆角边框（layer 自绘）
        self.wantsLayer = true
        self.layer?.borderColor = NSColor.separatorColor.cgColor
        self.layer?.borderWidth = 1
        self.layer?.cornerRadius = 5
        // masksToBounds=true 让 cornerRadius 真正生效（否则 documentView 会溢出圆角）
        self.layer?.masksToBounds = true

        // 4) 固定 24px 高（与单行字段纵向对齐，多行内容滚动）。
        self.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { nil }

    func textDidChange(_ notification: Notification) {
        onChange?()
        // v2.2.65：编辑期实时高亮 [[Page]] 双链。仅在非 IME 组字态下重排显示属性
        // （hasMarkedText 时不碰 storage，避免破坏拼音组字 / 光标定位）；仅改属性不改字符，
        // 不移动光标、不破坏 first-responder 链，与 v2.2.42 防护目标一致。
        guard !textView.hasMarkedText() else { return }
        highlightWikiLinks()
    }

    /// 开始编辑 → 仅重置 typingAttributes 为普通文字（字号 11），保证在 [[...]] 内输入新字符不继承链接色/下划线。
    func textDidBeginEditing(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv == textView else { return }
        tv.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
    }

    /// 结束编辑（失焦）→ 重新扫描 [[Page]] 应用链接属性，并重置 typingAttributes。
    func textDidEndEditing(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv == textView else { return }
        highlightWikiLinks()
    }

    /// 点击 [[Page]] / [[Page#anchor]] 超链接 → 跳转到对应 wiki 页。
    /// 仅在非编辑态（失焦高亮后）点击才触发；编辑态下 NSTextView 默认把链接点击当光标放置，不会误触。
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { return handleMeetinsightLink(url) }
        return false
    }

    /// 扫描 `[[Page]]` / `[[Page|alias]]` / `[[Page#anchor]]` / `[[Page|alias#anchor]]`，转成蓝色超链接。
    /// 不修改用户输入字符，只在显示层加属性。仅在加载（setStringValue）与失焦（textDidEndEditing）时调用。
    /// v2.2.42：不再于 textDidChange 调用，消除编辑期重排导致焦点/输入错乱的根因。
    private func highlightWikiLinks() {
        let raw = textView.string
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
        let pattern = "\\[\\[([^\\]\\n]+?)\\]\\]"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let nsStr = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: nsStr.length))
        guard let storage = textView.textStorage else { return }

        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: nsStr.length)
        storage.setAttributes(baseAttrs, range: fullRange)
        for m in matches {
            let r = m.range(at: 1)
            let content = nsStr.substring(with: r)
            // 拆分 alias 与 #anchor
            let firstSplit = content.components(separatedBy: "|")
            let left = firstSplit.first ?? content
            let pageAndAnchor = left.components(separatedBy: "#")
            let page = pageAndAnchor.first ?? left
            let anchor = pageAndAnchor.count > 1 ? pageAndAnchor[1] : ""
            var urlStr = "meetinsight://open-wiki/\(page.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page)"
            if !anchor.isEmpty {
                let a = (anchor.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? anchor)
                urlStr += "#\(a)"
            }
            if let url = URL(string: urlStr) {
                let linkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: url
                ]
                storage.addAttributes(linkAttrs, range: m.range)
            }
        }
        storage.endEditing()
        // 重置 typingAttributes → 输入新字符为普通文字色，不继承链接色/下划线。
        textView.typingAttributes = baseAttrs
    }

    /// 校验失败：在 layer 自绘边框之上叠红色边框（之后用户编辑会由 onChange 调 clearInvalid 复位）。
    func markInvalid() {
        self.layer?.borderColor = NSColor.systemRed.cgColor
        self.layer?.borderWidth = 1.5
    }
    /// 复位：恢复分隔色细边框（正常外观）。
    func clearInvalid() {
        self.layer?.borderColor = NSColor.separatorColor.cgColor
        self.layer?.borderWidth = 1
    }
}

// MARK: - 全站双链点击路由已由各 NSTextView 的 `clickedOnLink` 直接转发到 handleMeetinsightLink
// （见 WikiLinkTextView）。原 WikiLinkClickRouter 中间层从未被实例化，v2.2.44 已删除。

// MARK: - TagFieldView（v2.2.33 改造：pill 行 + addField 独立下行）
//
// 仿 Obsidian 笔记属性的多标签输入控件。
// - 上行（高 24）：pill 区，NSScrollView 容纳，多了横向滚动；末尾可显示「+ 添加」placeholder。
// - 下行（高 24）：独立的 NSTextField，Enter 添加 pill。
final class TagFieldView: NSView {
    private let pillScroll = NSScrollView()
    private let pillContainer = NSStackView()
    private let addField = ReturnInterceptField()
    private var pills: [String] = []
    var onChange: (() -> Void)?

    // 拦截 Return 的 NSTextField 子类：在别名/标签 addField 中按 Enter 时直接 commitAdd，
    // 避免被底部「确定」按钮的默认等价键抢走焦点，导致新 chip 不进数组（v2.2.64）。
    fileprivate final class ReturnInterceptField: NSTextField {
        weak var interceptTarget: TagFieldView?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 /* Return */ || event.characters == "\r" {
                interceptTarget?.commitAdd()
                return
            }
            super.keyDown(with: event)
        }
    }

    var tags: [String] { pills }

    func setTags(_ tags: [String]) {
        pills = tags.filter { !$0.isEmpty }
        rebuildPills()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // 上行 pill 区
        pillScroll.translatesAutoresizingMaskIntoConstraints = false
        pillScroll.hasVerticalScroller = false
        pillScroll.hasHorizontalScroller = true
        pillScroll.borderType = .noBorder
        pillScroll.drawsBackground = false
        pillScroll.autohidesScrollers = true
        addSubview(pillScroll)

        pillContainer.orientation = .horizontal
        pillContainer.spacing = 3
        pillContainer.alignment = .centerY
        pillContainer.translatesAutoresizingMaskIntoConstraints = false

        let pillDoc = NSView()
        pillDoc.translatesAutoresizingMaskIntoConstraints = false
        pillDoc.addSubview(pillContainer)
        pillScroll.documentView = pillDoc

        // 下行 addField
        addField.translatesAutoresizingMaskIntoConstraints = false
        addField.placeholderString = "+ 添加（按 Enter）"
        addField.font = .systemFont(ofSize: 12)
        addField.bezelStyle = .roundedBezel
        addField.target = self
        addField.action = #selector(commitAdd)
        addField.interceptTarget = self
        addSubview(addField)

        NSLayoutConstraint.activate([
            pillScroll.topAnchor.constraint(equalTo: topAnchor),
            pillScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            pillScroll.heightAnchor.constraint(equalToConstant: 24),

            addField.topAnchor.constraint(equalTo: pillScroll.bottomAnchor, constant: 4),
            addField.leadingAnchor.constraint(equalTo: leadingAnchor),
            addField.trailingAnchor.constraint(equalTo: trailingAnchor),
            addField.bottomAnchor.constraint(equalTo: bottomAnchor),
            addField.heightAnchor.constraint(equalToConstant: 24),

            pillContainer.topAnchor.constraint(equalTo: pillDoc.topAnchor, constant: 3),
            pillContainer.leadingAnchor.constraint(equalTo: pillDoc.leadingAnchor, constant: 5),
            pillContainer.trailingAnchor.constraint(lessThanOrEqualTo: pillDoc.trailingAnchor, constant: -5),
            pillContainer.bottomAnchor.constraint(equalTo: pillDoc.bottomAnchor, constant: -3),
            pillDoc.heightAnchor.constraint(equalTo: pillScroll.heightAnchor),
            pillDoc.widthAnchor.constraint(greaterThanOrEqualTo: pillScroll.widthAnchor)
        ])
        rebuildPills()
    }
    required init?(coder: NSCoder) { nil }

    private func rebuildPills() {
        for v in pillContainer.arrangedSubviews { v.removeFromSuperview() }
        for (i, tag) in pills.enumerated() {
            let pill = makePill(tag: tag, idx: i)
            pillContainer.addArrangedSubview(pill)
            pill.setContentHuggingPriority(.required, for: .horizontal)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pillContainer.addArrangedSubview(spacer)
    }

    private func makePill(tag: String, idx: Int) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 3
        pill.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor

        let label = NSTextField(labelWithString: tag)
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(title: "×", target: self, action: #selector(removePill(_:)))
        close.tag = idx
        close.bezelStyle = .inline
        close.isBordered = false
        close.font = .systemFont(ofSize: 11)
        close.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        pill.addSubview(close)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
            close.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 1),
            close.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 1),
            close.widthAnchor.constraint(equalToConstant: 14),
            close.heightAnchor.constraint(equalToConstant: 14)
        ])
        return pill
    }

    @objc private func commitAdd() {
        let raw = addField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        for p in parts where !pills.contains(p) { pills.append(p) }
        addField.stringValue = ""
        rebuildPills()
        onChange?()
        // 新 chip 加完后自动滚到最右，确保用户能看到刚添加的别名/标签（v2.2.64）
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let docWidth = self.pillScroll.documentView?.frame.width ?? 0
            let visibleWidth = self.pillScroll.contentView.bounds.width
            let x = max(0, docWidth - visibleWidth)
            self.pillScroll.contentView.scroll(to: NSPoint(x: x, y: 0))
            self.pillScroll.flashScrollers()
        }
    }

    @objc private func removePill(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0, idx < pills.count else { return }
        pills.remove(at: idx)
        rebuildPills()
        onChange?()
    }
}

// MARK: - TypeFieldView（v2.2.33 新增，与 TagFieldView 样式一致）
//
// 「类型」字段：popup 显示当前类型（撑满 outerStack.width - 100） + 下行独立的「+ 新建类型」按钮。
// popup 高度 24 与 WikiLinkTextField 等同，下行按钮 24，整体与 TagFieldView 视觉一致。
final class TypeFieldView: NSView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addBtn = NSButton(title: "+ 新建类型", target: nil, action: nil)
    var onChange: (() -> Void)?
    var onAddNew: (() -> Void)?

    var popupButton: NSPopUpButton { popup }
    var addButton: NSButton { addBtn }

    var items: [String] {
        (popup.itemArray as? [NSMenuItem])?.compactMap { $0.title } ?? []
    }

    func setItems(_ titles: [String]) {
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
    }

    func selectTitle(_ title: String) {
        popup.selectItem(withTitle: title)
    }

    var selectedTitle: String? { popup.titleOfSelectedItem }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.font = .systemFont(ofSize: 12)
        popup.heightAnchor.constraint(equalToConstant: 24).isActive = true
        popup.target = self
        popup.action = #selector(popupChanged)
        addSubview(popup)

        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.bezelStyle = .rounded
        addBtn.font = .systemFont(ofSize: 11)
        addBtn.target = self
        addBtn.action = #selector(addTapped)
        addSubview(addBtn)

        NSLayoutConstraint.activate([
            popup.topAnchor.constraint(equalTo: topAnchor),
            popup.leadingAnchor.constraint(equalTo: leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.heightAnchor.constraint(equalToConstant: 24),

            addBtn.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: 4),
            addBtn.trailingAnchor.constraint(equalTo: trailingAnchor),
            addBtn.bottomAnchor.constraint(equalTo: bottomAnchor),
            addBtn.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    required init?(coder: NSCoder) { nil }

    @objc private func popupChanged() { onChange?() }
    @objc private func addTapped() { onAddNew?() }
}

// MARK: - WikiPropertySheet（v2.2.33 全面升级）

/// 「新增 Wiki 页」全量属性表单 —— 模态 NSWindow。
final class WikiPropertySheet: NSViewController {

    private var initial: WikiPageSpec?

    // 通用字段
    // v2.2.65：nameField / updatedField 等全部单行字段改为 WikiLinkTextView，
    // 使「所有可输入文本处」都实时支持 [[双链]]（原 WikiLinkTextField 不支持双链渲染）。
    private var nameField: WikiLinkTextView!
    private var typeField: TypeFieldView!
    private var customTypes: [String] = []
    private var aliasesField: TagFieldView!
    private var tagsField: TagFieldView!
    private var updatedField: WikiLinkTextView!
    private var backlinksView: WikiLinkTextView!

    // person 字段
    private var personRows: NSStackView!
    private var chineseNameField: WikiLinkTextView!
    private var companyField: WikiLinkTextView!
    private var jobTitleField: WikiLinkTextView!
    private var roleField: WikiLinkTextView!

    // company 字段
    private var companyRows: NSStackView!
    private var companyTypeField: WikiLinkTextView!
    private var industryField: WikiLinkTextView!
    private var companyIntroView: WikiLinkTextView!

    // chip 字段
    private var chipRows: NSStackView!
    private var brandField: WikiLinkTextView!
    private var modelField: WikiLinkTextView!
    private var categoryField: WikiLinkTextView!
    private var functionView: WikiLinkTextView!
    private var statusField: WikiLinkTextView!
    private var replacementField: WikiLinkTextView!

    private var confirmBtn: NSButton!
    private var cancelBtn: NSButton!

    static let allTypes = ["Person", "Company", "Chip", "Project", "Topic", "Method"]

    // 自定义类型：持久化到 baseDir/005_LLMWiKi/custom_types.json，
    // 加载后会出现在「所有」Wiki 页属性面板的类型下拉中（跨页面、跨会话共享）。
    private static let customTypesURL: URL = AppConfig.shared.baseDir
        .appendingPathComponent("005_LLMWiKi")
        .appendingPathComponent("custom_types.json")

    static func loadCustomTypes() -> [String] {
        guard let data = try? Data(contentsOf: customTypesURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func saveCustomTypes(_ types: [String]) {
        var seen = Set<String>()
        var out: [String] = []
        for t in types {
            let v = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty && !seen.contains(v) { seen.insert(v); out.append(v) }
        }
        let data = try? JSONSerialization.data(withJSONObject: out, options: .fragmentsAllowed)
        try? data?.write(to: customTypesURL)
    }

    // 公共入口（静态方法，弹模态 NSWindow）。
    static func present(initial: WikiPageSpec? = nil, completion: @escaping (WikiPageSpec?) -> Void) {
        let vc = WikiPropertySheet(initial: initial)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = initial == nil ? "新增 WiKi 页" : "编辑 WiKi 页"
        panel.contentViewController = vc
        // 关键：把 panel 的 delegate 设为 vc，使无论通过「确定/取消」按钮，还是直接点
        // 红色关闭按钮（traffic-light）关闭窗口，都能触发 windowWillClose → NSApp.stopModal()，
        // 从而结束模态循环。否则仅靠按钮里的 stopModal，点红叉关闭后模态循环永不返回，
        // 主线程卡死，只能强制退出。
        panel.delegate = vc
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // 窗口尺寸按内容自适应（避免固定 780 高导致中部大片空白）；
        // 内容超高时由内部 NSScrollView 滚动，绝不裁剪。
        _ = vc.view
        // 先把宽度定为最终 620，让 scroll 内容宽度 = 592，再测量内容自然高度才准确
        panel.setContentSize(NSSize(width: 620, height: 560))
        vc.view.layoutSubtreeIfNeeded()
        let fit = vc.outerStack.fittingSize.height
        let h = min(max(fit + 28, 380), 680)
        panel.setContentSize(NSSize(width: 620, height: h))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        let result = vc.pendingResult
        vc.pendingResult = nil
        completion(result)
    }

    private var pendingResult: WikiPageSpec?
    /// 防止 NSApp.stopModal() 被重复调用（按钮关闭 与 windowWillClose 都可能触发）。
    private var stopped = false
    /// 主内容栈（供 refit() 读取其 fittingSize 按内容自适应窗口高度）。
    private var outerStack: NSStackView!

    init(initial: WikiPageSpec?) {
        self.initial = initial
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        populate(initial)
        if initial == nil {
            // 新页面默认带 wiki + 当前类型标签（与 pipeline 渲染产物一致）
            tagsField.setTags(["wiki", currentType()])
        }
        syncTypeSpecificVisibility()
    }

    private var didInitialFocus = false
    override func viewDidAppear() {
        super.viewDidAppear()
        // v2.2.44：默认把光标放进「规范名」一栏（首次即聚焦，避免需手动点）。
        // 仅聚焦一次，绝不抢回用户已主动移走的焦点。
        guard !didInitialFocus else { return }
        didInitialFocus = true
        // v2.2.65：nameField 现为 WikiLinkTextView（NSScrollView 子类），
        // 须聚焦其内嵌 textView，否则首响者落在 scrollView 上无法输入。
        view.window?.makeFirstResponder(nameField.textView)
    }

    private func buildUI() {
        // —— 行模板辅助 ——
        func makeFieldRow(label: String, control: NSView, labelWidth: CGFloat = 78) -> NSStackView {
            let lbl = NSTextField(labelWithString: label)
            lbl.font = .systemFont(ofSize: 12)
            lbl.textColor = .secondaryLabelColor
            lbl.alignment = .right
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            let row = NSStackView(views: [lbl, control])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return row
        }

        // —— 通用字段 ——
        nameField = WikiLinkTextView(frame: .zero)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.onChange = { [weak self] in self?.nameField.clearInvalid() }

        typeField = TypeFieldView(frame: .zero)
        typeField.translatesAutoresizingMaskIntoConstraints = false
        customTypes = Self.loadCustomTypes()
        typeField.setItems((Self.allTypes + customTypes).map { label(forType: $0) })
        typeField.onChange = { [weak self] in self?.syncTypeSpecificVisibility() }
        typeField.onAddNew = { [weak self] in self?.addCustomType() }

        aliasesField = TagFieldView(frame: .zero)
        aliasesField.translatesAutoresizingMaskIntoConstraints = false
        aliasesField.onChange = { [weak self] in self?.aliasesField.layer?.borderColor = NSColor.separatorColor.cgColor }

        tagsField = TagFieldView(frame: .zero)
        tagsField.translatesAutoresizingMaskIntoConstraints = false

        updatedField = WikiLinkTextView(frame: .zero)
        updatedField.translatesAutoresizingMaskIntoConstraints = false

        backlinksView = WikiLinkTextView(frame: .zero)
        backlinksView.translatesAutoresizingMaskIntoConstraints = false

        // —— person 字段 ——
        chineseNameField = WikiLinkTextView(frame: .zero); chineseNameField.translatesAutoresizingMaskIntoConstraints = false
        companyField  = WikiLinkTextView(frame: .zero); companyField.translatesAutoresizingMaskIntoConstraints = false
        jobTitleField = WikiLinkTextView(frame: .zero); jobTitleField.translatesAutoresizingMaskIntoConstraints = false
        roleField     = WikiLinkTextView(frame: .zero); roleField.translatesAutoresizingMaskIntoConstraints = false

        personRows = NSStackView(views: [
            makeFieldRow(label: "中文名", control: chineseNameField),
            makeFieldRow(label: "公司", control: companyField),
            makeFieldRow(label: "职位", control: jobTitleField),
            makeFieldRow(label: "职能范围", control: roleField)
        ])
        personRows.orientation = .vertical
        personRows.spacing = 4
        personRows.translatesAutoresizingMaskIntoConstraints = false

        // —— company 字段 ——
        companyTypeField = WikiLinkTextView(frame: .zero); companyTypeField.translatesAutoresizingMaskIntoConstraints = false
        industryField    = WikiLinkTextView(frame: .zero); industryField.translatesAutoresizingMaskIntoConstraints = false
        companyIntroView = WikiLinkTextView(frame: .zero);  companyIntroView.translatesAutoresizingMaskIntoConstraints = false

        companyRows = NSStackView(views: [
            makeFieldRow(label: "公司类型", control: companyTypeField),
            makeFieldRow(label: "所属行业", control: industryField),
            makeFieldRow(label: "公司简介", control: companyIntroView)
        ])
        companyRows.orientation = .vertical
        companyRows.spacing = 4
        companyRows.translatesAutoresizingMaskIntoConstraints = false

        // —— chip 字段 ——
        brandField       = WikiLinkTextView(frame: .zero); brandField.translatesAutoresizingMaskIntoConstraints = false
        modelField       = WikiLinkTextView(frame: .zero); modelField.translatesAutoresizingMaskIntoConstraints = false
        categoryField    = WikiLinkTextView(frame: .zero); categoryField.translatesAutoresizingMaskIntoConstraints = false
        functionView     = WikiLinkTextView(frame: .zero);  functionView.translatesAutoresizingMaskIntoConstraints = false
        statusField      = WikiLinkTextView(frame: .zero); statusField.translatesAutoresizingMaskIntoConstraints = false
        replacementField = WikiLinkTextView(frame: .zero); replacementField.translatesAutoresizingMaskIntoConstraints = false

        chipRows = NSStackView(views: [
            makeFieldRow(label: "品牌", control: brandField),
            makeFieldRow(label: "具体型号", control: modelField),
            makeFieldRow(label: "类别", control: categoryField),
            makeFieldRow(label: "功能简述", control: functionView),
            makeFieldRow(label: "状态", control: statusField),
            makeFieldRow(label: "替代料", control: replacementField)
        ])
        chipRows.orientation = .vertical
        chipRows.spacing = 4
        chipRows.translatesAutoresizingMaskIntoConstraints = false

        // —— 主布局 ——
        let mainStack = NSStackView(views: [
            makeFieldRow(label: "类型",       control: typeField),
            makeFieldRow(label: "规范名",     control: nameField),
            makeFieldRow(label: "别名",       control: aliasesField),
            personRows,    // 中文名 / 公司 / 职位 / 职能范围（仅 type=Person 时显示）
            companyRows,   // 公司类型 / 所属行业 / 公司简介（仅 type=Company 时显示；正好位于 aliases 与 tags 之间）
            chipRows,      // 品牌 / 具体型号 / 类别 / 功能简述 / 状态 / 替代料（仅 type=Chip 时显示）
            makeFieldRow(label: "标签",       control: tagsField),
            makeFieldRow(label: "更新",       control: updatedField),
            makeFieldRow(label: "反向链接",   control: backlinksView)
        ])
        mainStack.orientation = .vertical
        mainStack.spacing = 6
        mainStack.alignment = .leading
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        // 关键：让 person/company/chipRows 被 isHidden=true 时**真正折叠**（不留空白）。
        mainStack.detachesHiddenViews = true

        // —— 底部按钮 ——
        confirmBtn = NSButton(title: "确定", target: self, action: #selector(confirm))
        confirmBtn.bezelStyle = .rounded
        confirmBtn.font = .systemFont(ofSize: 12)
        confirmBtn.keyEquivalent = "\r"
        confirmBtn.keyEquivalentModifierMask = .command // v2.2.64：改为 Cmd+Enter 提交，避免抢走 addField 的 Enter
        confirmBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.font = .systemFont(ofSize: 12)
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [NSView(), cancelBtn, confirmBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)

        outerStack = NSStackView(views: [mainStack, buttonRow])
        outerStack.orientation = .vertical
        outerStack.spacing = 12
        outerStack.alignment = .leading
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            outerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            outerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            outerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            // 通用字段宽度（= 内容宽 - 100，左侧 14 标签 + 8 间距）
            nameField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            typeField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            aliasesField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            tagsField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            updatedField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            backlinksView.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            // person / company / chip 子字段同宽
            chineseNameField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            companyField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            jobTitleField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            roleField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            companyTypeField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            industryField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            companyIntroView.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            brandField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            modelField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            categoryField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            functionView.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            statusField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            replacementField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100)
        ])
    }

    /// 把 popup 的 display title 翻译回内部 type 值（TitleCase token）。
    private func typeFromLabel(_ label: String) -> String {
        if let l = label.range(of: "(")?.lowerBound,
           let r = label.range(of: ")", range: l..<label.endIndex) {
            return String(label[label.index(after: l)..<r.lowerBound])
        }
        if let sp = label.firstIndex(of: " ") {
            return String(label[label.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        }
        return label
    }

    private func label(forType t: String) -> String {
        switch t {
        case "Person":  return "👤 Person"
        case "Company": return "🏢 Company"
        case "Chip":    return "🔌 Chip"
        case "Project": return "📦 Project"
        case "Topic":   return "📚 Topic"
        case "Method":  return "🛠 Method"
        default:        return "📄 \(t)"
        }
    }

    private func syncTypeSpecificVisibility() {
        let t = currentType()
        personRows.isHidden  = (t != "Person")
        companyRows.isHidden = (t != "Company")
        chipRows.isHidden    = (t != "Chip")
        // 同步 tags 里的「类型 token」：始终保留 wiki + 当前类型
        var tg = tagsField.tags
        tg = tg.filter { !WikiPageSpec.typeTokens.contains($0) }
        if !tg.contains(t) { tg.append(t) }
        tagsField.setTags(tg)
        refit()
    }

    private func currentType() -> String {
        typeFromLabel(typeField.selectedTitle ?? "Person")
    }

    // MARK: - 自定义类型录入

    private func addCustomType() {
        let alert = NSAlert()
        alert.messageText = "新增自定义类型"
        alert.informativeText = "输入类型名称，将自动加入所有 WiKi 页「类型」下拉菜单（持久保存）。"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.placeholderString = "例如：客户 / 供应商 / 竞品"
        tf.bezelStyle = .roundedBezel
        tf.font = .systemFont(ofSize: 12)
        alert.accessoryView = tf
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        guard let win = view.window else { return }
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard let self else { return }
            if resp == .alertFirstButtonReturn {
                self.commitCustomType(tf.stringValue)
            }
        }
    }

    private func commitCustomType(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let illegal = CharacterSet(charactersIn: "():#\"'[]{}|,>%@!&*?/\\=+")
        if name.rangeOfCharacter(from: illegal) != nil || name.contains("\n") {
            let a = NSAlert()
            a.messageText = "类型名称含非法字符"
            a.informativeText = "请勿使用括号、冒号、井号、引号、斜杠等特殊符号，以免破坏 WiKi 文件。"
            a.addButton(withTitle: "知道了")
            if let win = view.window { a.beginSheetModal(for: win) { _ in } }
            return
        }
        let existing = Self.allTypes + customTypes
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            typeField.selectTitle(label(forType: name))
            syncTypeSpecificVisibility()
            return
        }
        customTypes.append(name)
        Self.saveCustomTypes(customTypes)
        let title = label(forType: name)
        typeField.setItems((Self.allTypes + customTypes).map { label(forType: $0) })
        typeField.selectTitle(title)
        syncTypeSpecificVisibility()
    }

    private func populate(_ s: WikiPageSpec?) {
        guard let s = s else { return }
        nameField.setStringValue(s.name)
        let title = label(forType: s.type)
        if (typeField.items).contains(title) {
            typeField.selectTitle(title)
        } else {
            // 自定义类型也要能加载
            typeField.setItems((Self.allTypes + customTypes).map { label(forType: $0) })
            typeField.selectTitle(title)
        }
        aliasesField.setTags(s.aliases)
        tagsField.setTags(s.tags)
        updatedField.setStringValue(s.updated)
        backlinksView.setStringValue(s.backlinks.joined(separator: "\n"))
        chineseNameField.setStringValue(s.chineseName)
        companyField.setStringValue(s.company)
        jobTitleField.setStringValue(s.jobTitle)
        roleField.setStringValue(s.role)
        companyTypeField.setStringValue(s.companyType)
        industryField.setStringValue(s.industry)
        companyIntroView.setStringValue(s.companyIntro)
        brandField.setStringValue(s.brand)
        modelField.setStringValue(s.model)
        categoryField.setStringValue(s.category)
        functionView.setStringValue(s.functionDesc)
        statusField.setStringValue(s.status)
        replacementField.setStringValue(s.replacement)
    }

    private func gather() -> WikiPageSpec {
        let type = currentType()
        let backlinks = backlinksView.stringValue
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return WikiPageSpec(
            name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            aliases: aliasesField.tags,
            tags: tagsField.tags,
            updated: updatedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            backlinks: backlinks,
            chineseName: chineseNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            company: companyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            jobTitle: jobTitleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            role: roleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            companyType: companyTypeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            industry: industryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            companyIntro: companyIntroView.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            brand: brandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            category: categoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            functionDesc: functionView.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            status: statusField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            replacement: replacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @objc private func confirm() {
        let s = gather()
        if s.name.isEmpty {
            NSSound.beep()
            nameField.markInvalid()
            view.window?.makeFirstResponder(nameField)
            return
        }
        pendingResult = s
        if !stopped { stopped = true; view.window?.performClose(nil); NSApp.stopModal() }
    }

    @objc private func cancel() {
        pendingResult = nil
        if !stopped { stopped = true; view.window?.performClose(nil); NSApp.stopModal() }
    }

    /// 按内容自然高度重新设定窗口尺寸（超高则滚动，绝不裁剪 / 空白）。
    private func refit() {
        guard let win = view.window else { return }
        outerStack.layoutSubtreeIfNeeded()
        let fit = outerStack.fittingSize.height
        let h = min(max(fit + 28, 380), 680)
        win.setContentSize(NSSize(width: 620, height: h))
    }
}

// MARK: - 窗口代理：任何关闭路径（按钮 / 红色 traffic-light）都结束模态循环，杜绝卡死
extension WikiPropertySheet: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard !stopped else { return }
        stopped = true
        NSApp.stopModal()
    }
}
