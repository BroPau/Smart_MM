//
//  MainContainerViewController.swift
//  Meetinsight
//
//  单窗口分页容器（无弹出窗口）：
//  - 顶部横向 tab 切换三个分页：纪要生成 / LLM Wiki / 设置。
//  - 默认选中「LLM Wiki」（显示 Wiki 首页，见需求 ⑤）。
//  - 顶部工具栏右侧「保存」按钮：对当前可保存分页（纪要生成 / LLM Wiki）触发保存。
//  - 对外暴露 selectTab(_:) / rebuildWiki() 供 AppDelegate 菜单调用。
//

import Cocoa

/// 可保存分页协议：当前页提供「保存」能力。
protocol SaveablePage: AnyObject {
    func saveCurrent()
}

enum MainTab: Int { case minutes = 0, generate = 1, wiki = 2, settings = 3 }

final class MainContainerViewController: NSViewController {

    private let saveBtn = NSButton(title: "💾 保存", target: nil, action: nil)

    private let contentView = NSView()

    private var tabButtons: [NSButton] = []
    private var pages: [MainTab: NSViewController] = [:]
    private var activeTab: MainTab = .minutes

    private var minutesVC: MinutesViewController { pages[.minutes] as! MinutesViewController }
    private var generateVC: GenerateViewController { pages[.generate] as! GenerateViewController }
    private var wikiVC: WikiViewController { pages[.wiki] as! WikiViewController }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        buildPages()
        selectTab(.minutes)   // 默认显示「会议纪要」页（需求 #6）
    }

    // MARK: - UI

    private func setupUI() {
        let pad: CGFloat = 14

        saveBtn.bezelStyle = .rounded
        saveBtn.target = self
        saveBtn.action = #selector(saveActive)

        // 创建 4 个 tab 按钮（会议纪要默认置顶）
        let tabDefs: [(MainTab, String)] = [
            (.minutes, "📝 会议纪要"),
            (.generate, "🎙 纪要生成"),
            (.wiki, "📚 LLM Wiki"),
            (.settings, "⚙️ 设置")
        ]
        for (tab, title) in tabDefs {
            let b = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
            b.bezelStyle = .rounded
            b.tag = tab.rawValue
            b.setButtonType(.toggle)
            b.alignment = .center
            tabButtons.append(b)
        }

        // 第 1 行：三个 tab 按钮组成的 tabGroup，整体真正水平居中
        let tabGroup = NSStackView(views: tabButtons)
        tabGroup.orientation = .horizontal
        tabGroup.spacing = 8
        tabGroup.alignment = .centerY
        tabGroup.translatesAutoresizingMaskIntoConstraints = false

        // tabRow 占满整行，tabGroup 用 centerX 约束钉在正中
        // （不依赖弹性 spacer 的 .fill 均分，居中绝对可靠）
        let tabRow = NSView()
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        tabRow.addSubview(tabGroup)
        NSLayoutConstraint.activate([
            tabGroup.centerXAnchor.constraint(equalTo: tabRow.centerXAnchor),
            tabGroup.topAnchor.constraint(equalTo: tabRow.topAnchor),
            tabGroup.bottomAnchor.constraint(equalTo: tabRow.bottomAnchor)
        ])

        // 第 2 行：右侧保存按钮（不再显示标题文字）
        let bottomSpacer = NSView()
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [bottomSpacer, saveBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.alignment = .centerY
        bottomRow.distribution = .fill
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        // 顶部栈：tabRow（居中）+ bottomRow（保存右对齐）
        let topBar = NSStackView(views: [tabRow, bottomRow])
        topBar.orientation = .vertical
        topBar.spacing = 4
        topBar.alignment = .leading
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.setContentHuggingPriority(.required, for: .vertical)
        topBar.setContentCompressionResistancePriority(.required, for: .vertical)

        contentView.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let body = NSView()
        body.wantsLayer = true
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(contentView)

        let stack = NSStackView(views: [topBar, body])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        stack.distribution = .fill
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad),
            // 让 topBar 吃满 stack 宽度
            topBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            // 让 tabRow 吃满 topBar 宽度（centerX 居中才有意义）
            tabRow.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            contentView.topAnchor.constraint(equalTo: body.topAnchor),
            contentView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func buildPages() {
        pages[.minutes] = MinutesViewController()
        pages[.generate] = GenerateViewController()
        pages[.wiki] = WikiViewController()
        pages[.settings] = SettingsViewController()
    }

    // MARK: - 切换

    @objc private func tabClicked(_ sender: NSButton) {
        guard let tab = MainTab(rawValue: sender.tag) else { return }
        selectTab(tab)
    }

    func selectTab(_ tab: MainTab) {
        activeTab = tab
        // 高亮当前按钮
        for b in tabButtons { b.state = (b.tag == tab.rawValue) ? .on : .off }

        // 移除旧页
        _ = children.first(where: { $0 === pages[tab] })  // 命中即同一页，无需切换（无需其他动作）
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        // 添加新页
        guard let vc = pages[tab] else { return }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        // 设置页不需要保存按钮
        saveBtn.isEnabled = (tab != .settings)
    }

    @objc private func saveActive() {
        if let saveable = pages[activeTab] as? SaveablePage {
            saveable.saveCurrent()
        }
    }

    // MARK: - 供菜单调用

    /// 切到 LLM Wiki 分页。
    func showWikiTab() { selectTab(.wiki) }

    /// 触发 LLM Wiki 重建。
    func rebuildWiki() { wikiVC.rebuildWikiFromExternal() }
}
