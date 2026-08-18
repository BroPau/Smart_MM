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
        var d: [String: Any] = [
            "类型": type,
            "规范名": name,
            "别名": aliases,
            "标签": tags,
            "更新时间": updated,
            "反向链接": backlinks
        ]
        switch type {
        case "Person":
            d["中文名"]    = chineseName
            d["公司"]      = company
            d["职位"]      = jobTitle
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
        default: break
        }
        return d
    }
}

// MARK: - WikiLinkTextField（v2.2.33 新增，替代 NSTextField）
//
// 单行文本输入控件，高度 24px（与 NSTextField 等同），可识别 `[[Page]]` 显示为蓝色超链接。
// 实现策略：内嵌一个 NSTextView 用 NSScrollView 包起来（isHorizontallyResizable=false → 自动单行折行），
// 在 textDidChange 时扫描 [[...]] 子串替换为带 .link 属性的 NSAttributedString。
// 点击超链接 → WikiLinkRouter.open(name:anchor:)。
final class WikiLinkTextField: NSView, NSTextViewDelegate {
    private let scroll = NSScrollView()
    let textView = NSTextView()
    var onChange: (() -> Void)?
    var stringValue: String { textView.string }

    func setStringValue(_ s: String) {
        textView.string = s
        highlightWikiLinks()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 与 NSTextField 视觉一致：roundedBezel 风格边框
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        addSubview(scroll)

        let tv = textView
        tv.font = .systemFont(ofSize: 12)
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = true  // 启用 attributed string 以支持超链接
        tv.allowsUndo = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainerInset = NSSize(width: 4, height: 3)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = self
        scroll.documentView = tv

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func textDidChange(_ notification: Notification) {
        highlightWikiLinks()
        onChange?()
    }

    /// 扫描 `[[Page]]` / `[[Page|alias]]` / `[[Page#anchor]]`，转成蓝色超链接。
    /// 不修改用户输入字符，只在显示层加属性。
    private func highlightWikiLinks() {
        let raw = textView.string
        let attr = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        attr.append(NSAttributedString(string: raw, attributes: baseAttrs))
        // 正则匹配 `[[Page]]` / `[[Page|alias]]` / `[[Page#anchor]]`
        let pattern = "\\[\\[([^\\]\\n]+?)\\]\\]"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let nsStr = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: nsStr.length))
        for m in matches {
            let r = m.range(at: 1)  // 内容（不含 [[ ]]）
            let content = nsStr.substring(with: r)
            let pageName = content.components(separatedBy: "|").first ?? content
            let page = pageName.components(separatedBy: "#").first ?? pageName
            // 用 meetinsight:// 协议避免被当作系统 URL
            let urlStr = "meetinsight://open-wiki/\(page.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page)"
            if let url = URL(string: urlStr) {
                let linkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: url
                ]
                attr.addAttributes(linkAttrs, range: m.range)
            }
        }
        // 替换不打断光标：用 NSTextStorage 替换并维护选中区间
        let selRanges = textView.selectedRanges
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.setAttributedString(attr)
            storage.endEditing()
        }
        textView.selectedRanges = selRanges
    }
}

// MARK: - WikiLinkTextView（v2.2.33 新增，替代多行 NSTextView）
//
// 多行版本，高度 24px（纵向对齐单行字段），内部 NSScrollView 提供纵向滚动。
// 同样的 [[Page]] 高亮 + 点击跳转。
final class WikiLinkTextView: NSView, NSTextViewDelegate {
    private let scroll = NSScrollView()
    let textView = NSTextView()
    var onChange: (() -> Void)?
    var stringValue: String { textView.string }

    func setStringValue(_ s: String) {
        textView.string = s
        highlightWikiLinks()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        addSubview(scroll)

        let tv = textView
        tv.font = .systemFont(ofSize: 11)
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 3)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.delegate = self
        scroll.documentView = tv

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func textDidChange(_ notification: Notification) {
        highlightWikiLinks()
        onChange?()
    }

    private func highlightWikiLinks() {
        let raw = textView.string
        let attr = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
        attr.append(NSAttributedString(string: raw, attributes: baseAttrs))
        let pattern = "\\[\\[([^\\]\\n]+?)\\]\\]"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let nsStr = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: nsStr.length))
        for m in matches {
            let r = m.range(at: 1)
            let content = nsStr.substring(with: r)
            let pageName = content.components(separatedBy: "|").first ?? content
            let page = pageName.components(separatedBy: "#").first ?? pageName
            let urlStr = "meetinsight://open-wiki/\(page.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page)"
            if let url = URL(string: urlStr) {
                let linkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: url
                ]
                attr.addAttributes(linkAttrs, range: m.range)
            }
        }
        let selRanges = textView.selectedRanges
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.setAttributedString(attr)
            storage.endEditing()
        }
        textView.selectedRanges = selRanges
    }
}

// MARK: - 全站拦截超链接点击 → WikiLinkRouter
//
// 任何 NSTextView 触发 url 委派时（点击 meetinsight://open-wiki/Page）调用此处。
// 既适用于 WikiLinkTextField/View，也适用于迁移期间系统后台弹出的页内 wikilink。
class WikiLinkClickRouter: NSObject, NSTextViewDelegate {
    weak var origDelegate: NSTextViewDelegate?
    func textView(_ textView: NSTextView, clickedOnLink url: URL, at charIndex: Int) -> Bool {
        if url.scheme == "meetinsight" {
            // 解析 host=open-wiki, path=/PageName
            let page = url.host == "open-wiki" ? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) :
                url.absoluteString.replacingOccurrences(of: "meetinsight://open-wiki/", with: "")
            if !page.isEmpty {
                WikiLinkRouter.open(name: page)
            }
            return true
        }
        return origDelegate?.textView?(textView, clickedOnLink: url, at: charIndex) ?? true
    }
}

// MARK: - TagFieldView（v2.2.33 改造：pill 行 + addField 独立下行）
//
// 仿 Obsidian 笔记属性的多标签输入控件。
// - 上行（高 24）：pill 区，NSScrollView 容纳，多了横向滚动；末尾可显示「+ 添加」placeholder。
// - 下行（高 24）：独立的 NSTextField，Enter 添加 pill。
final class TagFieldView: NSView {
    private let pillScroll = NSScrollView()
    private let pillContainer = NSStackView()
    private let addField = NSTextField()
    private var pills: [String] = []
    var onChange: (() -> Void)?

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
    private var nameField: WikiLinkTextField!
    private var typeField: TypeFieldView!
    private var customTypes: [String] = []
    private var aliasesField: TagFieldView!
    private var tagsField: TagFieldView!
    private var updatedField: WikiLinkTextField!
    private var backlinksView: WikiLinkTextView!

    // person 字段
    private var personRows: NSStackView!
    private var chineseNameField: WikiLinkTextField!
    private var companyField: WikiLinkTextField!
    private var jobTitleField: WikiLinkTextField!
    private var roleField: WikiLinkTextField!

    // company 字段
    private var companyRows: NSStackView!
    private var companyTypeField: WikiLinkTextField!
    private var industryField: WikiLinkTextField!
    private var companyIntroView: WikiLinkTextView!

    // chip 字段
    private var chipRows: NSStackView!
    private var brandField: WikiLinkTextField!
    private var modelField: WikiLinkTextField!
    private var categoryField: WikiLinkTextField!
    private var functionView: WikiLinkTextView!
    private var statusField: WikiLinkTextField!
    private var replacementField: WikiLinkTextField!

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
        nameField = WikiLinkTextField(frame: .zero)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.onChange = { [weak self] in self?.nameField.layer?.borderColor = NSColor.separatorColor.cgColor }

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

        updatedField = WikiLinkTextField(frame: .zero)
        updatedField.translatesAutoresizingMaskIntoConstraints = false

        backlinksView = WikiLinkTextView(frame: .zero)
        backlinksView.translatesAutoresizingMaskIntoConstraints = false

        // —— person 字段 ——
        chineseNameField = WikiLinkTextField(frame: .zero); chineseNameField.translatesAutoresizingMaskIntoConstraints = false
        companyField  = WikiLinkTextField(frame: .zero); companyField.translatesAutoresizingMaskIntoConstraints = false
        jobTitleField = WikiLinkTextField(frame: .zero); jobTitleField.translatesAutoresizingMaskIntoConstraints = false
        roleField     = WikiLinkTextField(frame: .zero); roleField.translatesAutoresizingMaskIntoConstraints = false

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
        companyTypeField = WikiLinkTextField(frame: .zero); companyTypeField.translatesAutoresizingMaskIntoConstraints = false
        industryField    = WikiLinkTextField(frame: .zero); industryField.translatesAutoresizingMaskIntoConstraints = false
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
        brandField       = WikiLinkTextField(frame: .zero); brandField.translatesAutoresizingMaskIntoConstraints = false
        modelField       = WikiLinkTextField(frame: .zero); modelField.translatesAutoresizingMaskIntoConstraints = false
        categoryField    = WikiLinkTextField(frame: .zero); categoryField.translatesAutoresizingMaskIntoConstraints = false
        functionView     = WikiLinkTextView(frame: .zero);  functionView.translatesAutoresizingMaskIntoConstraints = false
        statusField      = WikiLinkTextField(frame: .zero); statusField.translatesAutoresizingMaskIntoConstraints = false
        replacementField = WikiLinkTextField(frame: .zero); replacementField.translatesAutoresizingMaskIntoConstraints = false

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
            nameField.layer?.borderColor = NSColor.systemRed.cgColor
            nameField.layer?.borderWidth = 1
            view.window?.makeFirstResponder(nameField.textView)
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
