//
//  MinutesViewController.swift
//  Meetinsight
//
//  「会议纪要」分页（默认首页，已合并原「纪要生成」）——严格两列式（方案 B）：
//  布局骨架（显式约束，非 StackView 包裹，保证两列撑满窗口）：
//      顶部工具栏（固定高） / NSSplitView 两列主体（撑满剩余高度） / 底部状态条（固定高）
//  - 顶部工具栏：刷新 / 打开文件夹 / 导出 ▾（Markdown·Word·PDF·HTML·纯文本）/ 删除选中。
//  - 左栏（宽 280–520，默认 320，分界可拖动并持久化）自上而下：
//      ① 生成卡片（薄卡片常驻）：46pt 拖放区 + 选择音频… / 开始生成（运行时才出现「取消」）；
//         运行中卡片内展开进度条 + 状态 + 精简日志（进度就在左栏刷新），空闲时收起保持薄身；
//      ② 会议纪要列表（占据左栏主要高度，macOS 侧栏风格：无表头、单列、名称左 + 短日期右）；
//         · 「📋 会议纪要汇总」置顶，其余为 003_Meeting_Minutes 下的 .md（含导入子目录）；
//         · 导入的纪要带「导入」小徽标，与生成的纪要区分（名称本身不含前缀，改名干净）；
//         · 短日期：当天 → HH:mm；当年非当天 → M月d日；跨年 → yyyy年M月d日（按时间倒序即按年分组）；
//         · 双击行进入行内改名（Finder 逻辑，回车提交 / Esc 取消），改名即 rename 磁盘文件。
//      ③ 钉在左栏底部的「📥 导入会议纪要」按钮（复用 --import-docs 流程）；
//         列表占据「生成卡片」与按钮之间的剩余空间，按钮以 12pt 内缩稳居左栏底部，
//         始终完整可见——既不会因列表项少而被甩到中部，也不会贴死边被裁切。
//  - 右侧：
//      · 选中「汇总」→ 以汇总表格呈现所有纪要（名称 / 更新 / 大小），点击行打开对应纪要；
//      · 选中某纪要 → MarkdownEditorView 预览/编辑（点击进入编辑、保存写回 .md）。
//  - 生成完成后：提示「N 秒后自动跳转到新纪要」，5 秒后自动选中并打开新生成的纪要。
//  - 导出：原生实现，零额外依赖、沙箱离线可用（markdown→HTML 后用系统 textutil 转 docx/pdf）。
//

import Cocoa
import UniformTypeIdentifiers

private enum MinuteKind { case generated, bookImported }

private struct MinuteItem {
    let name: String      // 显示名（去 .md 后缀）
    let file: String      // 文件名
    let url: URL
    let updated: Date
    let size: Int64
    let kind: MinuteKind
}

private enum ExportFormat { case md, docx, pdf, html, txt }

final class MinutesViewController: NSViewController,
                                    NSTableViewDataSource, NSTableViewDelegate,
                                    NSTextFieldDelegate {

    // MARK: - 顶部工具栏
    private let refreshBtn = NSButton(title: "刷新", target: nil, action: nil)
    private let folderBtn = NSButton(title: "打开文件夹", target: nil, action: nil)
    private let exportBtn = NSPopUpButton(frame: .zero, pullsDown: true)
    private let deleteSelBtn = NSButton(title: "🗑 删除选中", target: nil, action: nil)

    // MARK: - 左侧：生成卡片
    private let genCard = NSView()
    private let genTitle = NSTextField(labelWithString: "🎙 生成会议纪要")
    private let dropView = DropView()
    private let audioField = NSTextField(labelWithString: "尚未选择音频文件")
    private let pickBtn = NSButton(title: "选择音频文件…", target: nil, action: nil)
    private let runZhBtn = NSButton(title: "生成中文纪要", target: nil, action: nil)
    private let runEnBtn = NSButton(title: "生成英文纪要", target: nil, action: nil)
    private let cancelBtn = NSButton(title: "取消", target: nil, action: nil)
    private let genProgressBar = NSProgressIndicator()
    private let genStatusLabel = NSTextField(labelWithString: "就绪")
    private let genLogTitle = NSTextField(labelWithString: "处理日志")
    private let genLogView = NSTextView()
    private let genLogScroll = NSScrollView()

    // MARK: - 左侧：列表 + 导入按钮
    private let tableView = NSTableView()
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private let importBtn = NSButton(title: "📥 导入会议纪要", target: nil, action: nil)

    // MARK: - 两列容器
    private let splitView = NSSplitView()
    private var didSetInitialSplit = false

    // MARK: - 右侧容器
    private let editor = MarkdownEditorView()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let rightContainer = NSView()

    // MARK: - 状态
    private var items: [MinuteItem] = []
    private var selectedIsSummary = true
    private var selectedItem: MinuteItem?
    private var currentMarkdown: String = ""
    private var currentSaveURL: URL?
    private var pendingSaveURL: URL?

    // 生成流程
    private var audioURL: URL?
    private var running = false
    /// 是否正在生成会议纪要（供 App 关窗 / 退出拦截判断）。
    var isGenerating: Bool { running }

    // 自动跳转
    private var programmaticSelect = false
    private var pendingAutoJump: DispatchWorkItem?

    private var minutesDir: URL { AppConfig.shared.baseDir.appendingPathComponent("003_Meeting_Minutes") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        editor.delegate = self
        loadMinutes()
    }

    // MARK: - UI 布局
    private func setupUI() {
        let pad: CGFloat = 16

        [refreshBtn, folderBtn, deleteSelBtn].forEach { b in
            b.target = self
            b.bezelStyle = .rounded
        }
        refreshBtn.action = #selector(refresh)
        folderBtn.action = #selector(openFolder)
        deleteSelBtn.action = #selector(deleteSelected)
        deleteSelBtn.isEnabled = false

        // 导出下拉（pullsDown：点击展开，选中格式后保持显示「导出 ▾」）
        exportBtn.target = self
        exportBtn.action = #selector(exportChosen)
        exportBtn.bezelStyle = .rounded
        exportBtn.addItem(withTitle: "导出 ▾")
        exportBtn.addItem(withTitle: "Markdown (.md)")
        exportBtn.addItem(withTitle: "Word (.docx)")
        exportBtn.addItem(withTitle: "PDF")
        exportBtn.addItem(withTitle: "HTML")
        exportBtn.addItem(withTitle: "纯文本 (.txt)")
        exportBtn.sizeToFit()

        let toolbar = NSStackView(views: [refreshBtn, folderBtn, exportBtn, deleteSelBtn])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.alignment = .centerY
        toolbar.distribution = .fill
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // —— 左侧：生成卡片（薄卡片，进度/日志仅运行时展开）——
        buildGenCard()

        // —— 左侧：纪要列表（macOS 侧栏风格：无表头、单列、名称 + 右侧短日期）——
        nameColumn.title = "会议纪要"
        nameColumn.isEditable = false
        nameColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(nameColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil                 // 侧栏不显示表头
        tableView.style = .inset
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.target = self
        tableView.doubleAction = #selector(listRowDoubleClicked)
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        listScroll.drawsBackground = false
        listScroll.documentView = tableView
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        importBtn.bezelStyle = .rounded
        importBtn.target = self
        importBtn.action = #selector(importMinutesAction)

        // 左侧栏：生成卡片（上）/ 列表（占生成卡片与导入按钮之间的剩余高度）/ 导入按钮（钉在左栏底部）
        //   [v2.2.19 修订] 回退 v2.2.18「列表自适应高度(min180/max320)+ 按钮紧贴列表下方」策略——
        //   该项策略在列表项数少时把按钮甩到左栏中部，显得过高、不协调。
        //   改为：列表撑满「生成卡片 ↔ 导入按钮」之间的剩余空间，按钮以 12pt 内缩稳居左栏底部，
        //   始终完整可见：既不会因列表项少被甩到中部，也不会贴死边被裁切。
        let leftSidebar = NSView()
        leftSidebar.translatesAutoresizingMaskIntoConstraints = false
        leftSidebar.addSubview(genCard)
        leftSidebar.addSubview(listScroll)
        leftSidebar.addSubview(importBtn)
        importBtn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leftSidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            leftSidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 520),

            genCard.topAnchor.constraint(equalTo: leftSidebar.topAnchor),
            genCard.leadingAnchor.constraint(equalTo: leftSidebar.leadingAnchor),
            genCard.trailingAnchor.constraint(equalTo: leftSidebar.trailingAnchor, constant: -1),

            // 列表占据生成卡片下方 → 导入按钮上方的剩余空间（无 min/max 高度封顶）
            listScroll.topAnchor.constraint(equalTo: genCard.bottomAnchor, constant: 10),
            listScroll.leadingAnchor.constraint(equalTo: leftSidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: leftSidebar.trailingAnchor, constant: -1),
            listScroll.bottomAnchor.constraint(equalTo: importBtn.topAnchor, constant: -10),

            // 导入按钮钉在左栏底部（小内缩 12pt），确保完整可见、不随列表长度乱飘；
            // 左右各收 10pt，使按钮比左栏略窄、更协调（仍完整显示）
            importBtn.leadingAnchor.constraint(equalTo: leftSidebar.leadingAnchor, constant: 10),
            importBtn.trailingAnchor.constraint(equalTo: leftSidebar.trailingAnchor, constant: -10),
            importBtn.heightAnchor.constraint(equalToConstant: 30),
            importBtn.bottomAnchor.constraint(equalTo: leftSidebar.bottomAnchor, constant: -12)
        ])

        // —— 右侧：MarkdownEditorView（汇总以 markdown 分类表格呈现，单独纪要以原文呈现）——
        rightContainer.wantsLayer = true
        rightContainer.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            editor.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor)
        ])
        editor.isHidden = false

        // —— 两列主体：左栏 | 右栏，可拖动分界，撑满窗口 ——
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MinutesSplitPosition2"
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(leftSidebar)
        splitView.addArrangedSubview(rightContainer)
        // 左栏保持宽度、右栏吸收窗口变化
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // 顶部工具栏（固定高）｜ 两列主体（撑满剩余）｜ 底部状态条（固定高）
        view.addSubview(toolbar)
        view.addSubview(splitView)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: pad),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -pad),

            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),

            statusLabel.topAnchor.constraint(equalTo: splitView.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 首次出现时给出默认分栏位置（autosave 已保存过则沿用用户拖动结果）
        guard !didSetInitialSplit else { return }
        didSetInitialSplit = true
        if splitView.subviews.first?.frame.width ?? 0 < 260 {
            splitView.setPosition(320, ofDividerAt: 0)
        }
    }

    // MARK: - 生成卡片
    private func buildGenCard() {
        genCard.wantsLayer = true
        genCard.layer?.cornerRadius = 10
        genCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        genCard.layer?.borderWidth = 1
        genCard.layer?.borderColor = NSColor.separatorColor.cgColor
        genCard.translatesAutoresizingMaskIntoConstraints = false

        genTitle.font = NSFont.boldSystemFont(ofSize: 13)
        genTitle.translatesAutoresizingMaskIntoConstraints = false

        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.heightAnchor.constraint(equalToConstant: 46).isActive = true
        dropView.onAudioDropped = { [weak self] url in self?.setAudio(url) }

        audioField.font = NSFont.systemFont(ofSize: 11)
        audioField.textColor = .secondaryLabelColor
        audioField.lineBreakMode = .byTruncatingMiddle
        audioField.translatesAutoresizingMaskIntoConstraints = false

        [pickBtn, runZhBtn, runEnBtn, cancelBtn].forEach { b in
            b.bezelStyle = .rounded
            b.alignment = .center
            b.font = NSFont.systemFont(ofSize: 12)
        }
        pickBtn.title = "选择音频…"
        runZhBtn.title = "生成中文纪要"
        runEnBtn.title = "生成英文纪要"
        runZhBtn.keyEquivalent = ""
        runEnBtn.keyEquivalent = ""
        pickBtn.target = self;  pickBtn.action = #selector(pickAudio)
        runZhBtn.target = self; runZhBtn.action = #selector(runPipelineZh)
        runEnBtn.target = self; runEnBtn.action = #selector(runPipelineEn)
        cancelBtn.target = self; cancelBtn.action = #selector(cancelRun)
        cancelBtn.isEnabled = false
        cancelBtn.isHidden = true       // 仅运行时出现

        let controlRow = NSStackView(views: [pickBtn, runZhBtn, runEnBtn, cancelBtn])
        controlRow.orientation = .horizontal
        controlRow.spacing = 6
        controlRow.alignment = .centerY
        controlRow.distribution = .fillEqually
        controlRow.translatesAutoresizingMaskIntoConstraints = false

        genProgressBar.style = .bar
        genProgressBar.minValue = 0
        genProgressBar.maxValue = 100
        genProgressBar.doubleValue = 0
        genProgressBar.isIndeterminate = false
        genProgressBar.controlSize = .small
        genProgressBar.isHidden = true   // 仅运行时出现
        genProgressBar.translatesAutoresizingMaskIntoConstraints = false

        genStatusLabel.font = NSFont.systemFont(ofSize: 11)
        genStatusLabel.textColor = .secondaryLabelColor
        genStatusLabel.lineBreakMode = .byTruncatingTail
        genStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        genLogTitle.isHidden = true      // 合并进日志区，默认收起
        genLogTitle.translatesAutoresizingMaskIntoConstraints = false

        genLogView.isEditable = false
        genLogView.isSelectable = true
        genLogView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        genLogView.backgroundColor = NSColor.textBackgroundColor
        genLogScroll.hasVerticalScroller = true
        genLogScroll.borderType = .noBorder
        genLogScroll.translatesAutoresizingMaskIntoConstraints = false
        genLogScroll.documentView = genLogView
        genLogScroll.heightAnchor.constraint(equalToConstant: 62).isActive = true
        genLogScroll.isHidden = true      // 仅运行时出现

        let genStack = NSStackView(views: [
            genTitle, dropView, audioField, controlRow,
            genProgressBar, genStatusLabel, genLogScroll
        ])
        genStack.orientation = .vertical
        genStack.spacing = 6
        genStack.alignment = .leading
        genStack.distribution = .fill
        genStack.translatesAutoresizingMaskIntoConstraints = false
        genStack.setHuggingPriority(.required, for: .vertical)

        genCard.addSubview(genStack)
        NSLayoutConstraint.activate([
            genStack.topAnchor.constraint(equalTo: genCard.topAnchor, constant: 10),
            genStack.leadingAnchor.constraint(equalTo: genCard.leadingAnchor, constant: 10),
            genStack.trailingAnchor.constraint(equalTo: genCard.trailingAnchor, constant: -10),
            genStack.bottomAnchor.constraint(equalTo: genCard.bottomAnchor, constant: -10),
            dropView.widthAnchor.constraint(equalTo: genStack.widthAnchor),
            audioField.widthAnchor.constraint(equalTo: genStack.widthAnchor),
            controlRow.widthAnchor.constraint(equalTo: genStack.widthAnchor),
            genProgressBar.widthAnchor.constraint(equalTo: genStack.widthAnchor),
            genStatusLabel.widthAnchor.constraint(equalTo: genStack.widthAnchor),
            genLogScroll.widthAnchor.constraint(equalTo: genStack.widthAnchor)
        ])
    }

    /// 运行态切换：进度条 / 状态 / 日志仅在跑流程时展开，空闲时卡片保持薄身。
    private func setRunningUI(_ on: Bool) {
        running = on
        runZhBtn.isEnabled = !on
        runEnBtn.isEnabled = !on
        pickBtn.isEnabled = !on
        cancelBtn.isHidden = !on
        cancelBtn.isEnabled = on
        genProgressBar.isHidden = !on
        // 运行中必显；结束后若有日志则保留可读，空日志则收起
        genLogScroll.isHidden = !on && genLogView.string.isEmpty
    }

    // MARK: - 加载纪要列表
    @objc private func refresh() { loadMinutes() }

    private func loadMinutes() {
        pendingAutoJump?.cancel(); pendingAutoJump = nil
        items = scanMinutes()
        tableView.reloadData()
        // 刷新共享 Wiki 索引，使纪要加载时即可做名词联动 / 自动双链（完成后由 WikiViewController 继续同步）
        WikiIndex.shared.refresh()
        // 默认选中「会议纪要汇总」
        selectedIsSummary = true
        selectedItem = nil
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showSummary()
        let gen = items.filter { $0.kind == .generated }.count
        let imp = items.filter { $0.kind == .bookImported }.count
        statusLabel.stringValue = items.isEmpty
            ? "003_Meeting_Minutes 暂无纪要"
            : "共 \(items.count) 份（生成 \(gen) · 导入 \(imp)）"
    }

    /// 递归扫描 003_Meeting_Minutes：顶层 .md 为「生成的纪要」，imported_* 子目录内 .md 为「导入的纪要」。
    private func scanMinutes() -> [MinuteItem] {
        let dir = minutesDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [MinuteItem] = []
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
            let kind: MinuteKind = parent.contains("imported") ? .bookImported : .generated
            let updated = vals?.contentModificationDate ?? Date.distantPast
            let size = Int64(vals?.fileSize ?? 0)
            out.append(MinuteItem(
                name: url.deletingPathExtension().lastPathComponent,
                file: url.lastPathComponent,
                url: url,
                updated: updated,
                size: size,
                kind: kind
            ))
        }
        out.sort { $0.updated > $1.updated }   // 最新的在前
        return out
    }

    // MARK: - 选中 / 展示
    private func selectRow(_ row: Int) {
        if row == 0 {
            selectedIsSummary = true
            selectedItem = nil
            showSummary()
        } else {
            let idx = row - 1
            guard idx >= 0, idx < items.count else { return }
            selectedIsSummary = false
            selectedItem = items[idx]
            showItem(items[idx])
        }
    }

    /// 会议纪要汇总（首页）：以 markdown 文档 + 分类表格呈现（按「生成的纪要 / 导入的纪要」分组），
    /// 每行纪要用 [[名称]] 双链，点击即打开对应纪要。不再使用 NSTableView 网格。
    private func showSummary() {
        editor.isHidden = false
        deleteSelBtn.isEnabled = false
        let gen = items.filter { $0.kind == .generated }
        let imp = items.filter { $0.kind == .bookImported }
        var md = "# 📋 会议纪要汇总\n\n"
        md += "> 点击任意纪要名称可打开查看 / 编辑。\n\n"
        md += "## 📊 概览\n"
        md += "- 共 **\(items.count)** 份：📝 生成 \(gen.count) · 📥 导入 \(imp.count)\n\n"
        md += summaryTableMarkdown(title: "📝 生成的纪要", items: gen)
        md += "\n"
        md += summaryTableMarkdown(title: "📥 导入的纪要", items: imp)
        editor.load(markdown: md, editable: false)
        // 纪要与 Wiki 页名都推给编辑器，使 [[名称]] 被识别为已知页（非缺失），点击可跳转
        editor.setWikiPages(items.map { $0.name } + WikiIndex.shared.wikiNames)
        statusLabel.stringValue = "会议纪要汇总（共 \(items.count) 份 · 生成 \(gen.count) · 导入 \(imp.count)）"
    }

    /// 生成 GFM 管道表格（名称｜类型｜更新｜大小），第一列用 [[名称]] 双链（名称不含前缀，确保与 setWikiPages 匹配）。
    private func summaryTableMarkdown(title: String, items: [MinuteItem]) -> String {
        guard !items.isEmpty else { return "## \(title)（0）\n\n（无）\n" }
        var s = "## \(title)（\(items.count)）\n\n"
        s += "| 名称 | 类型 | 更新 | 大小 |\n"
        s += "| --- | --- | --- | --- |\n"
        for it in items {
            let name = it.name.replacingOccurrences(of: "|", with: "／")
            let kind = (it.kind == .bookImported ? "导入" : "生成")
            s += "| [[\(name)]] | \(kind) | \(formatDateShort(it.updated)) | \(formatSize(it.size)) |\n"
        }
        return s
    }

    private func showItem(_ item: MinuteItem) {
        editor.isHidden = false
        // 已知页集合：Wiki 页名（用于名词联动跳转）+ 本列表纪要名（点击 [[纪要名]] 回到对应纪要）
        let knownPages = WikiIndex.shared.wikiNames + items.map { $0.name }
        editor.setWikiPages(knownPages)
        // 自动双链仅针对 Wiki 页名（人名/公司/品牌/型号），避免在纪要正文里把其他纪要名也强行包裹
        editor.setAutoLinkNames(WikiIndex.shared.wikiNames)
        if let text = try? String(contentsOf: item.url, encoding: .utf8) {
            currentMarkdown = text
            currentSaveURL = item.url
            // autoLink: 加载时把正文中出现的已知 Wiki 页名裸词包裹为 [[名称]]，点击即可跳转到 Wiki
            editor.load(markdown: text, editable: true, autoLink: true)
            statusLabel.stringValue = "\(item.name)（\(formatDateShort(item.updated))）"
        } else {
            currentMarkdown = ""
            currentSaveURL = nil
            editor.load(markdown: "（无法读取文件：\(item.url.path)）", editable: false)
        }
        deleteSelBtn.isEnabled = true
    }

    // MARK: - 工具栏动作
    @objc private func openFolder() {
        if FileManager.default.fileExists(atPath: minutesDir.path) {
            NSWorkspace.shared.open(minutesDir)
        } else {
            showAlert("会议纪要目录不存在：\(minutesDir.path)")
        }
    }

    @objc private func exportChosen() {
        let idx = exportBtn.indexOfSelectedItem
        guard idx >= 1 else { return }   // 0 是「导出 ▾」标题项
        let format: ExportFormat
        switch idx {
        case 1: format = .md
        case 2: format = .docx
        case 3: format = .pdf
        case 4: format = .html
        case 5: format = .txt
        default: return
        }
        guard let item = selectedItem else {
            showAlert("请先在左侧选择一份会议纪要再导出。")
            return
        }
        doExport(format, item: item)
    }

    private func doExport(_ format: ExportFormat, item: MinuteItem) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        let ext: String
        let ut: UTType?
        switch format {
        case .md:   ext = "md";   ut = UTType("text.markdown")
        case .docx: ext = "docx"; ut = UTType("org.openxmlformats.wordprocessingml.document")
        case .pdf:  ext = "pdf";  ut = .pdf
        case .html: ext = "html"; ut = .html
        case .txt:  ext = "txt";  ut = .plainText
        }
        panel.nameFieldStringValue = item.name + "." + ext
        if let ut { panel.allowedContentTypes = [ut] }
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.writeExport(format, item: item, to: url)
        }
    }

    private func writeExport(_ format: ExportFormat, item: MinuteItem, to url: URL) {
        let md = currentMarkdown
        do {
            switch format {
            case .md, .txt:
                try md.write(to: url, atomically: true, encoding: .utf8)
            case .html:
                try markdownToHTML(md).write(to: url, atomically: true, encoding: .utf8)
            case .docx, .pdf:
                let ok = runTextUtil(html: markdownToHTML(md),
                                     format: format == .docx ? "docx" : "pdf",
                                     destURL: url)
                if !ok {
                    showAlert("导出 \(format == .docx ? "Word" : "PDF") 失败：系统 textutil 不可用或被沙箱限制。已改为导出 HTML 副本。")
                    let fallback = url.deletingPathExtension().appendingPathExtension("html")
                    try? markdownToHTML(md).write(to: fallback, atomically: true, encoding: .utf8)
                    return
                }
            }
            statusLabel.stringValue = "已导出：\(url.lastPathComponent)"
        } catch {
            showAlert("导出失败：\(error.localizedDescription)")
        }
    }

    /// 调系统 textutil 把 HTML 转 docx/pdf，再拷到目标（目标 URL 由本进程持有 sandbox 授权）。
    private func runTextUtil(html: String, format: String, destURL: URL) -> Bool {
        let tmp = FileManager.default.temporaryDirectory
        let htmlURL = tmp.appendingPathComponent("mm_\(UUID().uuidString).html")
        let outURL = tmp.appendingPathComponent("mm_\(UUID().uuidString).\(format)")
        do { try html.write(to: htmlURL, atomically: true, encoding: .utf8) }
        catch { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-convert", format, htmlURL.path, "-output", outURL.path]
        let err = Pipe()
        proc.standardError = err
        do { try proc.run(); proc.waitUntilExit() }
        catch { return false }
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outURL.path) else { return false }
        do { try FileManager.default.copyItem(at: outURL, to: destURL) }
        catch { return false }
        try? FileManager.default.removeItem(at: htmlURL)
        try? FileManager.default.removeItem(at: outURL)
        return true
    }

    @objc private func deleteSelected() {
        guard let item = selectedItem, !selectedIsSummary else { return }
        let alert = NSAlert()
        alert.messageText = "确认删除「\(item.name)」？"
        alert.informativeText = "将永久删除该会议纪要文件（不可恢复）：\n\(item.file)"
        alert.alertStyle = .warning
        alert.icon = AppAlertIcon.warning.image
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.removeItem(at: item.url)
            loadMinutes()
        } catch {
            showAlert("删除失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 导入会议纪要（复用 --import-docs 流程）
    @objc private func importMinutesAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        var allowed: [UTType] = [.data, .plainText, .pdf, .commaSeparatedText,
                                UTType("org.openxmlformats.wordprocessingml.document"),
                                UTType("public.msword"),
                                UTType("org.openxmlformats.spreadsheetml.sheet"),
                                UTType("com.microsoft.excel"),
                                UTType("org.openxmlformats.email")].compactMap { $0 }
        allowed.append(.text)
        panel.allowedContentTypes = allowed
        panel.prompt = "导入会议纪要"
        panel.message = "选择一个或多个文档（或一个文件夹）。支持: .md/.txt/.csv/.doc/.docx/.pdf/.eml/.xls/.xlsx"
        panel.begin { [weak self] resp in
            guard resp == .OK, !panel.urls.isEmpty else { return }
            self?.runImportMinutes(urls: panel.urls)
        }
    }

    private func runImportMinutes(urls: [URL]) {
        let targetPath: String
        if urls.count == 1 {
            targetPath = urls[0].path
        } else {
            let stash = FileManager.default.temporaryDirectory
                .appendingPathComponent("smm_minutes_import_\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.createDirectory(at: stash, withIntermediateDirectories: true)
            for u in urls {
                let dest = stash.appendingPathComponent(u.lastPathComponent)
                try? FileManager.default.copyItem(at: u, to: dest)
            }
            targetPath = stash.path
        }
        importBtn.isEnabled = false
        genStatusLabel.stringValue = "正在导入会议纪要…"
        statusLabel.stringValue = "正在导入会议纪要…"
        PipelineRunner.shared.run(
            arguments: ["--json-log", "--import-docs", targetPath],
            progress: { [weak self] p in self?.genStatusLabel.stringValue = p.message },
            completion: { [weak self] result in
                guard let self else { return }
                self.importBtn.isEnabled = true
                if let err = result.error {
                    self.genStatusLabel.stringValue = "导入失败"
                    self.statusLabel.stringValue = "导入失败：\(err.localizedDescription)"
                    self.showAlert("导入失败：\(err.localizedDescription)")
                    return
                }
                self.loadMinutes()
                var msg = "导入完成"
                if let j = result.finalJSON {
                    let total = j["total"] as? Int ?? 0
                    let suc = (j["succeeded"] as? [String])?.count ?? 0
                    let fail = (j["failed"] as? [String])?.count ?? 0
                    msg = "导入成功 \(suc)/\(total)，失败 \(fail)"
                }
                self.genStatusLabel.stringValue = msg
                self.statusLabel.stringValue = msg
            }
        )
    }

    // MARK: - 生成流程（合并自原 GenerateViewController）
    private func setAudio(_ url: URL) {
        audioURL = url
        audioField.stringValue = url.lastPathComponent
        appendLog("已选择音频：\(url.lastPathComponent)")
    }

    @objc private func pickAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.setAudio(url)
        }
    }

    @objc private func runPipelineZh() { runPipeline(lang: "zh") }
    @objc private func runPipelineEn() { runPipeline(lang: "en") }

    private func runPipeline(lang: String) {
        guard let audio = audioURL else {
            showAlert("请先选择一段音频文件（或拖入）。")
            return
        }
        let audioDir = AppConfig.shared.baseDir.appendingPathComponent("001_Audio")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let dest = audioDir.appendingPathComponent(audio.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.copyItem(at: audio, to: dest)
        } catch {
            showAlert("无法复制音频到工作目录：\(error.localizedDescription)")
            return
        }

        genLogView.string = ""
        setRunningUI(true)
        genProgressBar.doubleValue = 0
        genStatusLabel.stringValue = "启动中…"
        appendLog("开始生成（\(lang == "en" ? "英文" : "中文")）：\(audio.lastPathComponent)")

        let langArg = (lang == "en") ? "en" : "zh"
        PipelineRunner.shared.run(
            arguments: ["--json-log", "--language", langArg],
            cancellable: true,
            progress: { [weak self] p in self?.handleProgress(p) },
            completion: { [weak self] result in self?.handleCompletion(result) }
        )
    }

    private func handleProgress(_ p: PipelineProgress) {
        if let prog = p.progress { genProgressBar.doubleValue = prog * 100 }
        genStatusLabel.stringValue = (p.step.map { "[\($0)] " } ?? "") + p.message
        appendLog("[\(p.level)] \(p.message)")
    }

    private func handleCompletion(_ result: PipelineResult) {
        setRunningUI(false)

        if let error = result.error {
            appendLog("❌ 失败：\(error.localizedDescription)")
            genStatusLabel.stringValue = "失败"
            showAlert("生成失败：\(error.localizedDescription)")
            return
        }

        let minutesDir = AppConfig.shared.baseDir.appendingPathComponent("003_Meeting_Minutes")
        guard let md = newestMarkdown(in: minutesDir) else {
            genStatusLabel.stringValue = "完成（未找到纪要）"
            appendLog("⚠️ 未在 003_Meeting_Minutes 找到纪要文件。")
            return
        }
        appendLog("✅ 已生成：\(md.lastPathComponent)")
        genStatusLabel.stringValue = "完成 · \(md.lastPathComponent)"
        // 刷新列表，并提示 5 秒后自动跳转到新纪要
        refreshAndSelect(url: md, autoJumpAfter: 5.0)
    }

    /// 刷新列表，展示提示，并在 delay 秒后自动选中并打开指定纪要；期间若用户手动切换则取消自动跳转。
    private func refreshAndSelect(url: URL, autoJumpAfter seconds: TimeInterval) {
        items = scanMinutes()
        tableView.reloadData()
        statusLabel.stringValue = "✅ 已生成《\(url.deletingPathExtension().lastPathComponent)》，\(Int(seconds)) 秒后自动跳转到新纪要…"
        pendingAutoJump?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let idx = self.items.firstIndex(where: { $0.url == url }) {
                self.programmaticSelect = true
                self.tableView.selectRowIndexes(IndexSet(integer: idx + 1), byExtendingSelection: false)
                self.statusLabel.stringValue = "已打开新纪要：\(url.lastPathComponent)"
            }
        }
        pendingAutoJump = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func cancelRun() {
        PipelineRunner.shared.cancel()
        appendLog("⏹ 已请求取消")
    }

    private func appendLog(_ s: String) {
        genLogView.string += s + "\n"
        genLogView.scrollToEndOfDocument(nil)
    }

    private func newestMarkdown(in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let mds = files.filter { $0.pathExtension == "md" }
        return mds.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
    }

    // MARK: - 改名（双击名称，类 macOS Finder）
    private func renameItem(_ item: MinuteItem, to newBase: String) {
        let newFile = newBase + ".md"
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newFile)
        if FileManager.default.fileExists(atPath: newURL.path) {
            showAlert("已存在同名纪要：「\(newFile)」，请换一个名称。")
            tableView.reloadData()
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
            if currentSaveURL == item.url { currentSaveURL = newURL }
            loadMinutes()
            if let newIdx = items.firstIndex(where: { $0.url == newURL }) {
                programmaticSelect = true
                tableView.selectRowIndexes(IndexSet(integer: newIdx + 1), byExtendingSelection: false)
            }
            statusLabel.stringValue = "已重命名为：\(newFile)"
        } catch {
            showAlert("重命名失败：\(error.localizedDescription)")
            tableView.reloadData()
        }
    }

    // MARK: - 工具
    private func showAlert(_ msg: String) {
        AppAlert.show(message: "会议纪要", informative: msg, icon: .minutes)
    }

    /// 短日期：当天 → HH:mm；当年非当天 → M月d日；跨年 → yyyy年M月d日。
    private func formatDateShort(_ d: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(d) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
        }
        let year = cal.component(.year, from: d)
        let thisYear = cal.component(.year, from: now)
        if year == thisYear {
            let f = DateFormatter(); f.dateFormat = "M月d日"; return f.string(from: d)
        }
        let f = DateFormatter(); f.dateFormat = "yyyy年M月d日"; return f.string(from: d)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    // MARK: - 极简 Markdown → HTML（供 textutil 转 docx/pdf/html 用）
    private func markdownToHTML(_ md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var html = ""
        var inCode = false
        var para: [String] = []
        func flush() {
            if !para.isEmpty {
                html += "<p>" + inline(para.joined(separator: "<br>")) + "</p>\n"
                para.removeAll()
            }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                flush()
                if !inCode { inCode = true; html += "<pre><code>\n" }
                else { inCode = false; html += "</code></pre>\n" }
                i += 1; continue
            }
            if inCode { html += escapeHtml(line) + "\n"; i += 1; continue }
            if line.hasPrefix("###") { flush(); html += "<h3>\(inline(clear(line, 4)))</h3>\n"; i += 1; continue }
            if line.hasPrefix("##")  { flush(); html += "<h2>\(inline(clear(line, 3)))</h2>\n"; i += 1; continue }
            if line.hasPrefix("#")   { flush(); html += "<h1>\(inline(clear(line, 2)))</h1>\n"; i += 1; continue }
            if line.hasPrefix(">")   { flush(); html += "<blockquote>\(inline(clear(line, 1)))</blockquote>\n"; i += 1; continue }
            if line.hasPrefix("---") { flush(); html += "<hr>\n"; i += 1; continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                var its: [String] = []
                while i < lines.count, lines[i].hasPrefix("- ") || lines[i].hasPrefix("* ") {
                    its.append("<li>" + inline(clear(lines[i], 2)) + "</li>")
                    i += 1
                }
                html += "<ul>" + its.joined() + "</ul>\n"; continue
            }
            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                flush()
                var its: [String] = []
                while i < lines.count, lines[i].range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                    let t = lines[i].replacingOccurrences(of: #"^\d+\.\s"#, with: "", options: .regularExpression)
                    its.append("<li>" + inline(t) + "</li>")
                    i += 1
                }
                html += "<ol>" + its.joined() + "</ol>\n"; continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); i += 1; continue }
            para.append(line); i += 1
        }
        flush()
        if inCode { html += "</code></pre>\n" }
        return "<html><head><meta charset=\"utf-8\"><style>body{font-family:-apple-system,'PingFang SC',sans-serif;line-height:1.6;max-width:780px;margin:24px auto;padding:0 16px}h1,h2,h3{margin:1.2em 0 .4em}pre{background:#f4f4f5;padding:12px;border-radius:8px;overflow:auto}code{background:#f4f4f5;padding:1px 5px;border-radius:4px}blockquote{color:#666;border-left:3px solid #ccc;margin:0;padding-left:12px}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:4px 8px}</style></head><body>\n" + html + "</body></html>"
    }

    private func clear(_ s: String, _ n: Int) -> String {
        String(s.dropFirst(n)).trimmingCharacters(in: .whitespaces)
    }
    private func escapeHtml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
    private func inline(_ s: String) -> String {
        var r = escapeHtml(s)
        r = r.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        r = r.replacingOccurrences(of: #"(?<!\*)\*(.+?)\*(?!\*)"#, with: "<em>$1</em>", options: .regularExpression)
        r = r.replacingOccurrences(of: #"`(.+?)`"#, with: "<code>$1</code>", options: .regularExpression)
        r = r.replacingOccurrences(of: #"\[(.+?)\]\((.+?)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        return r
    }

    // MARK: - NSTableViewDataSource / Delegate（左侧纪要列表）
    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count + 1   // 第 0 行是「会议纪要汇总」
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // 左侧侧栏：单列自绘行（名称 +「导入」标记 + 右侧短日期）
        let cell = MinuteRowView()
        if row == 0 {
            cell.configureSummary(count: items.count)
            return cell
        }
        guard row - 1 < items.count else { return nil }
        let item = items[row - 1]
        cell.configure(name: item.name,
                       date: formatDateShort(item.updated),
                       imported: item.kind == .bookImported)
        cell.nameField.delegate = self
        cell.nameField.tag = row          // tag 记录行号，供改名回调定位
        return cell
    }

    /// 双击行 → 进入改名（与 macOS Finder 一致：双击名称即可编辑，回车提交、Esc 取消）。
    @objc private func listRowDoubleClicked() {
        let row = tableView.clickedRow
        guard row > 0 else { return }
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MinuteRowView else { return }
        cell.beginRename()
    }

    /// 提交改名。
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, tf.tag > 0 else { return }
        (tf.superview as? MinuteRowView)?.endRename()
        let idx = tf.tag - 1
        guard idx < items.count else { return }
        let item = items[idx]
        var newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName.lowercased().hasSuffix(".md") { newName = String(newName.dropLast(3)) }
        guard !newName.isEmpty, newName != item.name else {
            tf.stringValue = item.name
            return
        }
        if newName.contains("/") || newName.contains(":") {
            tf.stringValue = item.name
            showAlert("名称中不能包含「/」或「:」。")
            return
        }
        renameItem(item, to: newName)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // 左侧列表
        if programmaticSelect {
            programmaticSelect = false
        } else {
            // 用户手动切换 → 取消待执行的自动跳转
            pendingAutoJump?.cancel()
            pendingAutoJump = nil
        }
        let rows = tableView.selectedRowIndexes
        guard rows.count == 1, let first = rows.first else {
            deleteSelBtn.isEnabled = (rows.count > 0)
            return
        }
        deleteSelBtn.isEnabled = (first != 0)
        selectRow(first)
    }
}

// MARK: - SaveablePage + MarkdownEditorViewDelegate
extension MinutesViewController: MarkdownEditorViewDelegate, SaveablePage {
    func saveCurrent() {
        guard currentSaveURL != nil else {
            showAlert("尚无已选择的纪要可保存。")
            return
        }
        pendingSaveURL = currentSaveURL
        editor.requestSave()
    }

    func markdownEditorDidRequestSave(_ editor: MarkdownEditorView, markdown: String) {
        guard let url = pendingSaveURL else { return }
        pendingSaveURL = nil
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            currentMarkdown = markdown
            statusLabel.stringValue = "已保存 · \(url.lastPathComponent)"
        } catch {
            showAlert("保存失败：\(error.localizedDescription)")
        }
    }

    func markdownEditorDidClickWikilink(_ editor: MarkdownEditorView, name: String, anchor: String?) {
        // 汇总页里的 [[纪要名]] 点击 -> 优先打开对应纪要（名称可能带「📥 」前缀，去掉后再匹配）
        let clean = name.replacingOccurrences(of: "📥 ", with: "").trimmingCharacters(in: .whitespaces)
        if let item = items.first(where: { $0.name == clean }) {
            selectedIsSummary = false
            selectedItem = item
            if let idx = items.firstIndex(where: { $0.file == item.file }) {
                tableView.selectRowIndexes(IndexSet(integer: idx + 1), byExtendingSelection: false)
            }
            showItem(item)
            return
        }
        // 否则路由到 LLM WiKi 页（容器负责切到 WiKi 分页并打开；未命中则提示新建）
        (self.parent as? MainContainerViewController)?.openWikiPage(name, anchor: anchor)
    }

    func markdownEditorRequestsPageList(_ editor: MarkdownEditorView) -> [String] { [] }

    func markdownEditorPreviewForWikilink(_ editor: MarkdownEditorView, name: String) -> String? { nil }
}

// MARK: - 侧栏行视图：名称 +「导入」标记 + 右侧短日期，双击可改名
fileprivate final class MinuteRowView: NSTableCellView {

    let nameField = NSTextField()
    private let badge = NSTextField(labelWithString: "导入")
    private let dateField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.font = NSFont.systemFont(ofSize: 13)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badge.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = NSColor.separatorColor.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false

        dateField.font = NSFont.systemFont(ofSize: 11)
        dateField.textColor = .tertiaryLabelColor
        dateField.alignment = .right
        dateField.translatesAutoresizingMaskIntoConstraints = false
        dateField.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(nameField)
        addSubview(badge)
        addSubview(dateField)
        textField = nameField
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),

            badge.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 5),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 14),

            dateField.leadingAnchor.constraint(greaterThanOrEqualTo: badge.trailingAnchor, constant: 6),
            dateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dateField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(name: String, date: String, imported: Bool) {
        nameField.stringValue = name
        nameField.font = NSFont.systemFont(ofSize: 13)
        nameField.textColor = .labelColor
        dateField.stringValue = date
        dateField.isHidden = false
        badge.isHidden = !imported
        endRename()
    }

    func configureSummary(count: Int) {
        nameField.stringValue = "📋 会议纪要汇总"
        nameField.font = NSFont.boldSystemFont(ofSize: 13)
        nameField.textColor = .labelColor
        nameField.tag = 0
        nameField.delegate = nil
        dateField.stringValue = count > 0 ? "\(count)" : ""
        badge.isHidden = true
        endRename()
    }

    /// 进入行内改名（选中全部文本，回车提交 / Esc 取消）。
    func beginRename() {
        guard nameField.tag > 0 else { return }
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBordered = true
        nameField.bezelStyle = .roundedBezel
        nameField.drawsBackground = true
        window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    func endRename() {
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBordered = false
        nameField.drawsBackground = false
    }
}

// MARK: - 拖放区（合并后迁移到本文件）
fileprivate final class DropView: NSView {
    var onAudioDropped: ((URL) -> Void)?

    private let label = NSTextField(labelWithString: "🎙 拖放音频到此处")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.cornerRadius = 10
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlight(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return false }
        for url in items {
            if isAudio(url) { onAudioDropped?(url); return true }
        }
        return false
    }

    private func isAudio(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .audio)
        }
        return ["mp3", "wav", "m4a", "aac", "flac", "ogg", "caf"].contains(url.pathExtension.lowercased())
    }

    private func highlight(_ on: Bool) {
        layer?.borderColor = on ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
    }
}
