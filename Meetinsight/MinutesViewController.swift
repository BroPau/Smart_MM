//
//  MinutesViewController.swift
//  Meetinsight
//
//  「会议纪要」分页（默认首页）：
//  - 顶部工具栏：刷新 / 打开文件夹 / 导出 ▾（Markdown·Word·PDF·HTML·纯文本）/ 删除选中。
//  - 左侧：会议纪要列表（「📋 会议纪要汇总」置顶，其余为 003_Meeting_Minutes 下的 .md）。
//  - 右侧：
//      · 选中「汇总」→ 以汇总表格呈现所有纪要（名称 / 更新 / 大小），点击行打开对应纪要（#7）；
//      · 选中某纪要 → MarkdownEditorView 预览/编辑（点击进入编辑、保存写回 .md）。
//  - 导出：原生实现，零额外依赖、沙箱离线可用（markdown→HTML 后用系统 textutil 转 docx/pdf）。
//

import Cocoa
import UniformTypeIdentifiers

private struct MinuteItem {
    let name: String      // 显示名（去 .md 后缀）
    let file: String      // 文件名
    let url: URL
    let updated: Date
    let size: Int64
}

private enum ExportFormat { case md, docx, pdf, html, txt }

final class MinutesViewController: NSViewController,
                                    NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - UI 组件
    private let refreshBtn = NSButton(title: "刷新", target: nil, action: nil)
    private let folderBtn = NSButton(title: "打开文件夹", target: nil, action: nil)
    private let exportBtn = NSPopUpButton(frame: .zero, pullsDown: true)
    private let deleteSelBtn = NSButton(title: "🗑 删除选中", target: nil, action: nil)

    private let tableView = NSTableView()
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))

    private let editor = MarkdownEditorView()
    private let statusLabel = NSTextField(labelWithString: "就绪")

    // 右侧容器：同时托管 editor 与汇总表格，按选中项切换显隐
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

        // 左侧列表
        nameColumn.title = "会议纪要"; nameColumn.width = 240
        dateColumn.title = "更新"; dateColumn.width = 130
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
        listScroll.widthAnchor.constraint(equalToConstant: 320).isActive = true

        // 右侧：editor + 汇总表格
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

        // 左右可拖动分界（仿 Wiki / 纪要生成页）
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "MinutesSplitPosition"
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentHuggingPriority(.defaultLow, for: .horizontal)
        split.addSubview(listScroll)
        split.addSubview(rightContainer)

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

    // MARK: - 加载纪要列表
    @objc private func refresh() { loadMinutes() }

    private func loadMinutes() {
        items = scanMinutes()
        tableView.reloadData()
        // 默认选中「会议纪要汇总」
        selectedIsSummary = true
        selectedItem = nil
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showSummary()
        statusLabel.stringValue = items.isEmpty
            ? "003_Meeting_Minutes 暂无纪要"
            : "共 \(items.count) 份会议纪要"
    }

    private func scanMinutes() -> [MinuteItem] {
        let dir = minutesDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }
        let mds = files.filter { $0.pathExtension.lowercased() == "md" }
        var out: [MinuteItem] = []
        for f in mds {
            let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let updated = vals?.contentModificationDate ?? Date.distantPast
            let size = Int64(vals?.fileSize ?? 0)
            out.append(MinuteItem(
                name: f.deletingPathExtension().lastPathComponent,
                file: f.lastPathComponent,
                url: f,
                updated: updated,
                size: size
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
        statusLabel.stringValue = "会议纪要汇总（共 \(items.count) 份）"
    }

    private func showItem(_ item: MinuteItem) {
        summaryScroll.isHidden = true
        editor.isHidden = false
        if let text = try? String(contentsOf: item.url, encoding: .utf8) {
            currentMarkdown = text
            currentSaveURL = item.url
            editor.load(markdown: text, editable: true)
            statusLabel.stringValue = "\(item.name)（\(formatDate(item.updated))）"
        } else {
            currentMarkdown = ""
            currentSaveURL = nil
            editor.load(markdown: "（无法读取文件：\(item.url.path)）", editable: false)
        }
        deleteSelBtn.isEnabled = true
        editor.setWikiPages([])
    }

    // MARK: - 汇总表格（#7）
    private func configureSummaryTable() {
        sumNameCol.title = "名称"; sumNameCol.width = 240
        sumDateCol.title = "更新"; sumDateCol.width = 140
        sumSizeCol.title = "大小"; sumSizeCol.width = 100
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
                    // 兜底：写一份 HTML 到同目录
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

    // MARK: - 工具
    private func showAlert(_ msg: String) {
        AppAlert.show(message: "会议纪要", informative: msg, icon: .minutes)
    }

    private func formatDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: d)
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
            case sumNameCol: value = item.name
            case sumDateCol: value = formatDate(item.updated)
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
        let value: String = (tableColumn === nameColumn) ? item.name : formatDate(item.updated)
        let cell = NSTextField(labelWithString: value)
        cell.lineBreakMode = .byTruncatingTail
        return cell
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
