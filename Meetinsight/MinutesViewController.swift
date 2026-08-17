//
//  MinutesViewController.swift
//  Meetinsight
//
//  「会议纪要」分页（默认首页，已合并原「纪要生成」）：
//  - 顶部工具栏：刷新 / 打开文件夹 / 导出 ▾（Markdown·Word·PDF·HTML·纯文本）/ 删除选中。
//  - 左侧栏（自上而下）：
//      ① 生成卡片（常驻）：拖放音频 / 选择音频文件 / 开始生成 / 取消 / 进度（进度在卡片内刷新）/ 处理日志；
//      ② 会议纪要列表（「📋 会议纪要汇总」置顶，其余为 003_Meeting_Minutes 下的 .md，含导入的纪要子目录）；
//         · 区分「生成的纪要」与「导入的纪要」（导入项以 📥 标记）；
//         · 列表时间使用短格式（当天 → HH:mm；当年非当天 → M月d日；跨年 → yyyy年M月d日）；
//         · 双击名称即可改名（与 macOS Finder 一致）。
//      ③ 列表底部「📥 导入会议纪要」按钮（复用 --import-docs 流程）。
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
                                    NSTableViewDataSource, NSTableViewDelegate {

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
    private let runBtn = NSButton(title: "开始生成", target: nil, action: nil)
    private let cancelBtn = NSButton(title: "取消", target: nil, action: nil)
    private let genProgressBar = NSProgressIndicator()
    private let genStatusLabel = NSTextField(labelWithString: "就绪")
    private let genLogTitle = NSTextField(labelWithString: "处理日志")
    private let genLogView = NSTextView()
    private let genLogScroll = NSScrollView()

    // MARK: - 左侧：列表 + 导入按钮
    private let tableView = NSTableView()
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
    private let importBtn = NSButton(title: "📥 导入会议纪要", target: nil, action: nil)

    // MARK: - 右侧容器
    private let editor = MarkdownEditorView()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let rightContainer = NSView()
    private let summaryScroll = NSScrollView()
    private let summaryTable = NSTableView()
    private let sumNameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sumName"))
    private let sumDateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sumDate"))
    private let sumSizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sumSize"))

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

        // —— 左侧：生成卡片 ——
        buildGenCard()

        // —— 左侧：列表 ——
        nameColumn.title = "会议纪要"; nameColumn.width = 220
        dateColumn.title = "更新"; dateColumn.width = 110
        nameColumn.isEditable = true          // 支持双击改名
        dateColumn.isEditable = false
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(dateColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.documentView = tableView
        listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        importBtn.bezelStyle = .rounded
        importBtn.target = self
        importBtn.action = #selector(importMinutesAction)
        importBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true

        // 左侧栏：生成卡片（上）/ 列表（中，撑开）/ 导入按钮（下）
        let leftSidebar = NSView()
        leftSidebar.translatesAutoresizingMaskIntoConstraints = false
        leftSidebar.wantsLayer = true
        leftSidebar.addSubview(genCard)
        leftSidebar.addSubview(listScroll)
        leftSidebar.addSubview(importBtn)
        NSLayoutConstraint.activate([
            genCard.topAnchor.constraint(equalTo: leftSidebar.topAnchor),
            genCard.leadingAnchor.constraint(equalTo: leftSidebar.leadingAnchor),
            genCard.trailingAnchor.constraint(equalTo: leftSidebar.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: genCard.bottomAnchor, constant: 10),
            listScroll.leadingAnchor.constraint(equalTo: leftSidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: leftSidebar.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: importBtn.topAnchor, constant: -10),
            importBtn.leadingAnchor.constraint(equalTo: leftSidebar.leadingAnchor),
            importBtn.trailingAnchor.constraint(equalTo: leftSidebar.trailingAnchor),
            importBtn.bottomAnchor.constraint(equalTo: leftSidebar.bottomAnchor)
        ])

        // —— 右侧：editor + 汇总表格 ——
        configureSummaryTable()
        rightContainer.wantsLayer = true
        rightContainer.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        summaryScroll.translatesAutoresizingMaskIntoConstraints = false
        summaryScroll.hasVerticalScroller = true
        summaryScroll.documentView = summaryTable
        rightContainer.addSubview(editor)
        rightContainer.addSubview(summaryScroll)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            editor.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
            summaryScroll.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            summaryScroll.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            summaryScroll.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            summaryScroll.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor)
        ])
        summaryScroll.isHidden = true
        editor.isHidden = false

        // —— 左右可拖动分界 ——
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "MinutesSplitPosition"
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentHuggingPriority(.defaultLow, for: .horizontal)
        split.addSubview(leftSidebar)
        split.addSubview(rightContainer)
        split.setPosition(360, ofDividerAt: 0)

        let bottomRow = NSStackView(views: [statusLabel])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.alignment = .centerY
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [toolbar, split, bottomRow])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad),
            split.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
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
        dropView.heightAnchor.constraint(equalToConstant: 60).isActive = true
        dropView.onAudioDropped = { [weak self] url in self?.setAudio(url) }

        audioField.preferredMaxLayoutWidth = 240
        audioField.lineBreakMode = .byTruncatingMiddle
        audioField.translatesAutoresizingMaskIntoConstraints = false

        [pickBtn, runBtn, cancelBtn].forEach { b in
            b.bezelStyle = .rounded
            b.alignment = .center
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        }
        pickBtn.target = self; pickBtn.action = #selector(pickAudio)
        runBtn.target = self;   runBtn.action = #selector(runPipeline)
        cancelBtn.target = self; cancelBtn.action = #selector(cancelRun)
        cancelBtn.isEnabled = false

        let controlRow = NSStackView(views: [pickBtn, runBtn, cancelBtn])
        controlRow.orientation = .horizontal
        controlRow.spacing = 8
        controlRow.alignment = .centerY
        controlRow.distribution = .fillEqually
        controlRow.translatesAutoresizingMaskIntoConstraints = false

        genProgressBar.style = .bar
        genProgressBar.minValue = 0
        genProgressBar.maxValue = 100
        genProgressBar.doubleValue = 0
        genProgressBar.isIndeterminate = false
        genProgressBar.translatesAutoresizingMaskIntoConstraints = false

        genStatusLabel.font = NSFont.systemFont(ofSize: 12)
        genStatusLabel.textColor = .secondaryLabelColor
        genStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        genLogTitle.font = NSFont.boldSystemFont(ofSize: 11)
        genLogTitle.textColor = .tertiaryLabelColor
        genLogTitle.translatesAutoresizingMaskIntoConstraints = false

        genLogView.isEditable = false
        genLogView.isSelectable = true
        genLogView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        genLogView.backgroundColor = NSColor.textBackgroundColor
        genLogScroll.hasVerticalScroller = true
        genLogScroll.translatesAutoresizingMaskIntoConstraints = false
        genLogScroll.documentView = genLogView
        genLogScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true

        let genStack = NSStackView(views: [
            genTitle, dropView, audioField, controlRow,
            genProgressBar, genStatusLabel, genLogTitle, genLogScroll
        ])
        genStack.orientation = .vertical
        genStack.spacing = 8
        genStack.alignment = .leading
        genStack.distribution = .fill
        genStack.translatesAutoresizingMaskIntoConstraints = false
        genStack.setHuggingPriority(.defaultHigh, for: .vertical)

        genCard.addSubview(genStack)
        NSLayoutConstraint.activate([
            genStack.topAnchor.constraint(equalTo: genCard.topAnchor, constant: 12),
            genStack.leadingAnchor.constraint(equalTo: genCard.leadingAnchor, constant: 12),
            genStack.trailingAnchor.constraint(equalTo: genCard.trailingAnchor, constant: -12),
            genStack.bottomAnchor.constraint(equalTo: genCard.bottomAnchor, constant: -12),
            dropView.widthAnchor.constraint(equalTo: genStack.widthAnchor),
            controlRow.widthAnchor.constraint(equalTo: genStack.widthAnchor),
            genProgressBar.widthAnchor.constraint(equalTo: genStack.widthAnchor),
            genLogScroll.widthAnchor.constraint(equalTo: genStack.widthAnchor)
        ])
    }

    // MARK: - 加载纪要列表
    @objc private func refresh() { loadMinutes() }

    private func loadMinutes() {
        pendingAutoJump?.cancel(); pendingAutoJump = nil
        items = scanMinutes()
        tableView.reloadData()
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

    private func showSummary() {
        summaryScroll.isHidden = false
        editor.isHidden = true
        summaryTable.reloadData()
        deleteSelBtn.isEnabled = false
        let gen = items.filter { $0.kind == .generated }.count
        let imp = items.filter { $0.kind == .bookImported }.count
        statusLabel.stringValue = "会议纪要汇总（共 \(items.count) 份 · 生成 \(gen) · 导入 \(imp)）"
    }

    private func showItem(_ item: MinuteItem) {
        summaryScroll.isHidden = true
        editor.isHidden = false
        if let text = try? String(contentsOf: item.url, encoding: .utf8) {
            currentMarkdown = text
            currentSaveURL = item.url
            editor.load(markdown: text, editable: true)
            statusLabel.stringValue = "\(item.name)（\(formatDateShort(item.updated))）"
        } else {
            currentMarkdown = ""
            currentSaveURL = nil
            editor.load(markdown: "（无法读取文件：\(item.url.path)）", editable: false)
        }
        deleteSelBtn.isEnabled = true
        editor.setWikiPages([])
    }

    // MARK: - 汇总表格
    private func configureSummaryTable() {
        sumNameCol.title = "名称"; sumNameCol.width = 220
        sumDateCol.title = "更新"; sumDateCol.width = 120
        sumSizeCol.title = "大小"; sumSizeCol.width = 90
        for c in [sumNameCol, sumDateCol, sumSizeCol] { summaryTable.addTableColumn(c) }
        summaryTable.dataSource = self
        summaryTable.delegate = self
        summaryTable.headerView = NSTableHeaderView()
        summaryTable.allowsEmptySelection = true
        summaryTable.allowsMultipleSelection = false
        summaryTable.allowsColumnReordering = false
        summaryTable.allowsColumnResizing = true
        summaryTable.target = self
        summaryTable.doubleAction = #selector(summaryRowDoubleClicked)
    }

    @objc private func summaryRowDoubleClicked() {
        let row = summaryTable.clickedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if let idx = items.firstIndex(where: { $0.file == item.file }) {
            tableView.selectRowIndexes(IndexSet(integer: idx + 1), byExtendingSelection: false)
        }
        selectedIsSummary = false
        selectedItem = item
        showItem(item)
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

    @objc private func runPipeline() {
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

        running = true
        runBtn.isEnabled = false
        cancelBtn.isEnabled = true
        genProgressBar.doubleValue = 0
        genStatusLabel.stringValue = "启动中…"
        genLogView.string = ""
        appendLog("开始生成：\(audio.lastPathComponent)")

        PipelineRunner.shared.run(
            arguments: ["--json-log"],
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
        running = false
        runBtn.isEnabled = true
        cancelBtn.isEnabled = false

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

    // MARK: - NSTableViewDataSource / Delegate（左侧列表 + 右侧汇总表共用）
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === summaryTable { return items.count }
        return items.count + 1   // 第 0 行是「会议纪要汇总」
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === summaryTable {
            guard row < items.count else { return nil }
            let item = items[row]
            let value: String
            switch tableColumn {
            case sumNameCol: value = (item.kind == .bookImported ? "📥 " : "") + item.name
            case sumDateCol: value = formatDateShort(item.updated)
            case sumSizeCol: value = formatSize(item.size)
            default:         value = item.name
            }
            let cell = NSTextField(labelWithString: value)
            cell.lineBreakMode = .byTruncatingTail
            return cell
        }
        // 左侧列表
        if row == 0 {
            let cell = NSTextField(labelWithString: "📋 会议纪要汇总")
            cell.font = NSFont.boldSystemFont(ofSize: 13)
            return cell
        }
        guard row - 1 < items.count else { return nil }
        let item = items[row - 1]
        if tableColumn === nameColumn {
            let cellView = NSTableCellView()
            let prefix = (item.kind == .bookImported) ? "📥 " : ""
            let tf = NSTextField()
            tf.stringValue = prefix + item.name
            tf.isEditable = true
            tf.isBordered = false
            tf.drawsBackground = false
            tf.font = NSFont.systemFont(ofSize: 13)
            tf.lineBreakMode = .byTruncatingTail
            cellView.addSubview(tf)
            tf.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
            ])
            cellView.textField = tf
            return cellView
        } else {
            let cell = NSTextField(labelWithString: formatDateShort(item.updated))
            cell.lineBreakMode = .byTruncatingTail
            return cell
        }
    }

    /// 提交改名（双击名称编辑结束后由 NSTableView 回调）。
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard tableView === self.tableView,
              let col = tableColumn, col === nameColumn,
              row > 0 else { return }
        let idx = row - 1
        guard idx < items.count else { return }
        let item = items[idx]
        var newName = (object as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if newName.isEmpty { tableView.reloadData(); return }
        if newName.lowercased().hasSuffix(".md") { newName = String(newName.dropLast(3)) }
        if newName.isEmpty { tableView.reloadData(); return }
        renameItem(item, to: newName)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // 右侧汇总表：单击行打开对应纪要
        if let tv = notification.object as? NSTableView, tv === summaryTable {
            let rows = summaryTable.selectedRowIndexes
            guard rows.count == 1, let first = rows.first, first < items.count else { return }
            let item = items[first]
            if let idx = items.firstIndex(where: { $0.file == item.file }) {
                tableView.selectRowIndexes(IndexSet(integer: idx + 1), byExtendingSelection: false)
            }
            selectedIsSummary = false
            selectedItem = item
            showItem(item)
            return
        }
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

    func markdownEditorDidClickWikilink(_ editor: MarkdownEditorView, name: String) {
        // 会议纪要页无 Wiki 页面跳转；忽略。
    }

    func markdownEditorRequestsPageList(_ editor: MarkdownEditorView) -> [String] { [] }

    func markdownEditorPreviewForWikilink(_ editor: MarkdownEditorView, name: String) -> String? { nil }
}

// MARK: - 拖放区（合并后迁移到本文件）
fileprivate final class DropView: NSView {
    var onAudioDropped: ((URL) -> Void)?

    private let label = NSTextField(labelWithString: "🎙 拖放音频文件到此处（或点「选择音频文件…」）")

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
