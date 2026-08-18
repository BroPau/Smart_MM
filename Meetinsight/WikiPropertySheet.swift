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

import Cocoa

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
            "type": type,
            "canonical_name": name,
            "aliases": aliases,
            "tags": tags,
            "updated": updated,
            "backlinks": backlinks
        ]
        switch type {
        case "Person":
            d["中文名"]    = chineseName
            d["company"]   = company
            d["title"]     = jobTitle
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

// MARK: - TagFieldView（标签 pill 输入框：× 删除 / + 添加 / Enter 添加）

/// 仿 Obsidian 笔记属性的多标签输入控件。一行显示所有 pill，末尾 + 输入框。
final class TagFieldView: NSView {
    private let scrollView = NSScrollView()
    private let container = NSStackView()
    private let addField = NSTextField()
    private var pills: [String] = []
    var onChange: (() -> Void)?

    var tags: [String] { pills }

    func setTags(_ tags: [String]) {
        pills = tags.filter { !$0.isEmpty }
        rebuild()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        container.orientation = .horizontal
        container.spacing = 3
        container.alignment = .centerY
        container.distribution = .fill
        container.translatesAutoresizingMaskIntoConstraints = false

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(container)
        scrollView.documentView = doc

        addField.placeholderString = "+ 添加"
        addField.isBordered = false
        addField.drawsBackground = false
        addField.font = .systemFont(ofSize: 11)
        addField.target = self
        addField.action = #selector(addPill)
        addField.translatesAutoresizingMaskIntoConstraints = false
        addField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addField.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        doc.addSubview(addField)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 24),
            container.topAnchor.constraint(equalTo: doc.topAnchor, constant: 3),
            container.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 5),
            container.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -5),
            container.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -3),
            addField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            addField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            doc.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { nil }

    private func rebuild() {
        // 清掉旧 pill（保留 addField 不动；它不是 container 子视图）
        for v in container.arrangedSubviews { v.removeFromSuperview() }
        for (i, tag) in pills.enumerated() {
            let pill = makePill(tag: tag, idx: i)
            container.addArrangedSubview(pill)
            pill.setContentHuggingPriority(.required, for: .horizontal)
        }
        // spacer 把 addField 推到 pill 之后
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(spacer)
        container.addArrangedSubview(addField)
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

    @objc private func addPill() {
        let raw = addField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 也允许一次粘贴 "a,b,c" 一次加多个
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        for p in parts where !pills.contains(p) { pills.append(p) }
        addField.stringValue = ""
        rebuild()
        onChange?()
    }

    @objc private func removePill(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0, idx < pills.count else { return }
        pills.remove(at: idx)
        rebuild()
        onChange?()
    }
}

// MARK: - WikiPropertySheet

/// 「新增 Wiki 页」全量属性表单 —— 模态 NSWindow。
final class WikiPropertySheet: NSViewController {

    private var initial: WikiPageSpec?

    // 通用字段
    private var nameField: NSTextField!
    private var typePopup: NSPopUpButton!
    private var addTypeBtn: NSButton!
    private var customTypes: [String] = []
    private var aliasesField: TagFieldView!
    private var tagsField: TagFieldView!
    private var updatedField: NSTextField!
    private var backlinksView: NSTextView!

    // person 字段
    private var personRows: NSStackView!
    private var chineseNameField: NSTextField!
    private var companyField: NSTextField!
    private var jobTitleField: NSTextField!
    private var roleField: NSTextField!

    // company 字段
    private var companyRows: NSStackView!
    private var companyTypeField: NSTextField!
    private var industryField: NSTextField!
    private var companyIntroView: NSTextView!

    // chip 字段
    private var chipRows: NSStackView!
    private var brandField: NSTextField!
    private var modelField: NSTextField!
    private var categoryField: NSTextField!
    private var functionView: NSTextView!
    private var statusField: NSTextField!
    private var replacementField: NSTextField!

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
        // 访问 vc.view 即可触发 loadView（macOS 的 NSViewController 自动加载），无需 loadViewIfNeeded()（仅 14+）
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
        func makeTF(placeholder: String) -> NSTextField {
            let tf = NSTextField()
            tf.placeholderString = placeholder
            tf.bezelStyle = .roundedBezel
            tf.font = .systemFont(ofSize: 12)
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return tf
        }
        func makeMultilineTV(minHeight: CGFloat = 64) -> NSTextView {
            let tv = NSTextView()
            tv.isEditable = true
            tv.isSelectable = true
            tv.font = .systemFont(ofSize: 11)
            tv.textContainerInset = NSSize(width: 4, height: 3)
            tv.translatesAutoresizingMaskIntoConstraints = false
            tv.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
            return tv
        }

        // —— 通用字段 ——
        nameField  = makeTF(placeholder: "规范名（必填）")
        typePopup  = NSPopUpButton(frame: .zero, pullsDown: false)
        typePopup.translatesAutoresizingMaskIntoConstraints = false
        typePopup.font = .systemFont(ofSize: 12)
        customTypes = Self.loadCustomTypes()
        typePopup.addItems(withTitles: (Self.allTypes + customTypes).map { label(forType: $0) })
        typePopup.target = self
        typePopup.action = #selector(typeChanged)
        typePopup.heightAnchor.constraint(equalToConstant: 22).isActive = true

        addTypeBtn = NSButton(title: "+", target: self, action: #selector(addCustomType))
        addTypeBtn.toolTip = "新增自定义类型（将共享到所有 WiKi 页的类型下拉）"
        addTypeBtn.bezelStyle = .rounded
        addTypeBtn.font = .systemFont(ofSize: 12)
        addTypeBtn.translatesAutoresizingMaskIntoConstraints = false
        aliasesField = TagFieldView(frame: .zero)
        aliasesField.translatesAutoresizingMaskIntoConstraints = false
        aliasesField.onChange = { [weak self] in self?.aliasesField.layer?.borderColor = NSColor.separatorColor.cgColor }
        tagsField = TagFieldView(frame: .zero)
        tagsField.translatesAutoresizingMaskIntoConstraints = false
        updatedField = makeTF(placeholder: "YYYY-MM-DD（留空 = 今日）")
        backlinksView = makeMultilineTV(minHeight: 64)

        // —— person 字段 ——
        chineseNameField = makeTF(placeholder: "（待补全）")
        companyField  = makeTF(placeholder: "（待补全）")
        jobTitleField = makeTF(placeholder: "（待补全）")
        roleField     = makeTF(placeholder: "（待补全）")

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
        companyTypeField = makeTF(placeholder: "（待补全）")
        industryField    = makeTF(placeholder: "（待补全）")
        companyIntroView = makeMultilineTV(minHeight: 60)

        companyRows = NSStackView(views: [
            makeFieldRow(label: "公司类型", control: companyTypeField),
            makeFieldRow(label: "所属行业", control: industryField),
            makeFieldRow(label: "公司简介", control: withScroll(companyIntroView, height: 70))
        ])
        companyRows.orientation = .vertical
        companyRows.spacing = 4
        companyRows.translatesAutoresizingMaskIntoConstraints = false

        // —— chip 字段 ——
        brandField       = makeTF(placeholder: "（待补全）")
        modelField       = makeTF(placeholder: "（待补全）")
        categoryField    = makeTF(placeholder: "（待补全）")
        functionView     = makeMultilineTV(minHeight: 60)
        statusField      = makeTF(placeholder: "（待补全）")
        replacementField = makeTF(placeholder: "（待补全）")

        chipRows = NSStackView(views: [
            makeFieldRow(label: "品牌", control: brandField),
            makeFieldRow(label: "具体型号", control: modelField),
            makeFieldRow(label: "类别", control: categoryField),
            makeFieldRow(label: "功能简述", control: withScroll(functionView, height: 70)),
            makeFieldRow(label: "状态", control: statusField),
            makeFieldRow(label: "替代料", control: replacementField)
        ])
        chipRows.orientation = .vertical
        chipRows.spacing = 4
        chipRows.translatesAutoresizingMaskIntoConstraints = false

        // —— 主布局 ——
        // 用一个垂直 NSStackView 把所有字段串起来，不再嵌在 NSScrollView 里。
        // 老版本使用 ScrollView + autolayout documentView 时，主栈只约束到
        // documentView 顶部/底部，但 documentView 没有显式高度约束，会导致
        // Auto Layout 把内容整体下推到 documentView 下半部、上半部留下大段
        // 空白（典型症状：「新增 Wiki 页」对话框上半屏漆黑一片、字段全挤在底部）。
        // 改为单一 stackView 后，所有字段按顺序从顶部开始排列，溢出靠外层
        // dialog 尺寸自适应（panel height 已在 present() 中设为 700，正常足够）。
        let typeRowStack = NSStackView(views: [typePopup, addTypeBtn])
        typeRowStack.orientation = .horizontal
        typeRowStack.spacing = 6
        typeRowStack.alignment = .centerY
        typeRowStack.distribution = .fill
        typeRowStack.translatesAutoresizingMaskIntoConstraints = false
        addTypeBtn.setContentHuggingPriority(.required, for: .horizontal)
        let mainStack = NSStackView(views: [
            makeFieldRow(label: "类型",   control: typeRowStack),
            makeFieldRow(label: "规范名", control: nameField),
            personRows,
            makeFieldRow(label: "别名",   control: aliasesField),
            companyRows,
            chipRows,
            makeFieldRow(label: "标签",   control: tagsField),
            makeFieldRow(label: "更新",   control: updatedField),
            makeFieldRow(label: "反向链接", control: withScroll(backlinksView, height: 72))
        ])
        mainStack.orientation = .vertical
        mainStack.spacing = 6
        mainStack.alignment = .leading
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        // 关键：让 person/company/chipRows 被 isHidden=true 时**真正折叠**（不留空白）。
        // NSStackView 的 detachesHiddenViews 默认 false，会让被隐藏的 arrangedSubview
        // 仍然占据布局空间 —— 这就是之前「类型选 Company 时还是看到一大片 Person/Chip 空字段」的根因。
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

        // —— 总布局：单一外层垂直栈 = [mainStack, buttonRow]，直接放进 view ——
        // 窗口高度在 present() / refit() 里按内容 fittingSize 自适应，不再写死 780 高；
        // 面板高度 = 内容高 → 无中部空白、各类型字段（含 chip 6 行）均落在 380–680 上限内不外溢。
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
            typePopup.widthAnchor.constraint(equalToConstant: 180),
            aliasesField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            tagsField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100),
            updatedField.widthAnchor.constraint(equalTo: outerStack.widthAnchor, constant: -100)
        ])
    }

    /// 把 NSTextView 嵌进 NSScrollView，返回可放入 NSStackView 的容器。
    private func withScroll(_ tv: NSTextView, height: CGFloat) -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tv
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    /// 把 popup 的 display title 翻译回内部 type 值（TitleCase token）。
    private func typeFromLabel(_ label: String) -> String {
        // 新格式："👤 Person" / "🏢 Company" / ... —— 去掉开头 emoji 与前导空格即可。
        // 同时兼容历史格式 "👤 人名 (Person)"（去掉括号内部）和自定义类型 "📄 FooBar"。
        if let l = label.range(of: "(")?.lowerBound,
           let r = label.range(of: ")", range: l..<label.endIndex) {
            return String(label[label.index(after: l)..<r.lowerBound])
        }
        // 去掉 emoji（粗略：去掉首个 token 前的空格分界，截取第二段；并去掉尾部空格）。
        if let sp = label.firstIndex(of: " ") {
            return String(label[label.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        }
        return label
    }

    private func label(forType t: String) -> String {
        // 严格 TitleCase（如用户要求「类型用首字母大写」），emoji 保持辨识度。
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

    @objc private func typeChanged() {
        syncTypeSpecificVisibility()
    }

    private func syncTypeSpecificVisibility() {
        let t = currentType()
        personRows.isHidden  = (t != "Person")
        companyRows.isHidden = (t != "Company")
        chipRows.isHidden    = (t != "Chip")
        // 同步 tags 里的「类型 token」：始终保留 wiki + 当前类型，避免切换类型后残留旧类型标签
        var tg = tagsField.tags
        tg = tg.filter { !WikiPageSpec.typeTokens.contains($0) }
        if !tg.contains(t) { tg.append(t) }
        tagsField.setTags(tg)
        // 切换类型会改变可见字段数 → 重新按内容高度自适应窗口尺寸
        refit()
    }

    private func currentType() -> String {
        typeFromLabel(typePopup.titleOfSelectedItem ?? "Person")
    }

    // MARK: - 自定义类型录入

    @objc private func addCustomType() {
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
        // 禁止特殊字符，避免破坏 YAML frontmatter 的 type 字段
        let illegal = CharacterSet(charactersIn: "():#\"'[]{}|,>%@!&*?/\\=+")
        if name.rangeOfCharacter(from: illegal) != nil || name.contains("\n") {
            let a = NSAlert()
            a.messageText = "类型名称含非法字符"
            a.informativeText = "请勿使用括号、冒号、井号、引号、斜杠等特殊符号，以免破坏 WiKi 文件。"
            a.addButton(withTitle: "知道了")
            if let win = view.window { a.beginSheetModal(for: win) { _ in } }
            return
        }
        // 与内置类型、已有自定义类型去重（忽略大小写）
        let existing = Self.allTypes + customTypes
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            typePopup.selectItem(withTitle: label(forType: name))
            syncTypeSpecificVisibility()
            return
        }
        customTypes.append(name)
        Self.saveCustomTypes(customTypes)
        let title = label(forType: name)
        typePopup.addItem(withTitle: title)
        typePopup.selectItem(withTitle: title)
        syncTypeSpecificVisibility()
    }

    private func populate(_ s: WikiPageSpec?) {
        guard let s = s else { return }
        nameField.stringValue = s.name
        let title = label(forType: s.type)
        if typePopup.item(withTitle: title) != nil {
            typePopup.selectItem(withTitle: title)
        } else {
            typePopup.addItem(withTitle: title)
            typePopup.selectItem(withTitle: title)
        }
        aliasesField.setTags(s.aliases)
        tagsField.setTags(s.tags)
        updatedField.stringValue = s.updated
        backlinksView.string = s.backlinks.joined(separator: "\n")
        chineseNameField.stringValue = s.chineseName
        companyField.stringValue   = s.company
        jobTitleField.stringValue  = s.jobTitle
        roleField.stringValue      = s.role
        companyTypeField.stringValue = s.companyType
        industryField.stringValue    = s.industry
        companyIntroView.string      = s.companyIntro
        brandField.stringValue       = s.brand
        modelField.stringValue       = s.model
        categoryField.stringValue    = s.category
        functionView.string          = s.functionDesc
        statusField.stringValue      = s.status
        replacementField.stringValue = s.replacement
    }

    private func gather() -> WikiPageSpec {
        let type = currentType()
        let backlinks = backlinksView.string
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
            companyIntro: companyIntroView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            brand: brandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            category: categoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            functionDesc: functionView.string.trimmingCharacters(in: .whitespacesAndNewlines),
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
            nameField.becomeFirstResponder()
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