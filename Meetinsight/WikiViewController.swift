//
//  WikiViewController.swift
//  Meetinsight
//
//  「LLM Wiki」分页（分页 ②）：
//  - 顶部工具栏：搜索栏 + Wiki 首页按钮 + 重建 Wiki / 刷新索引 / 打开文件夹 / ＋新增 / 保存。
//  - 左侧：页面列表（Wiki 首页始终置顶，其余来自 `pipeline.py --list-wiki-pages`）。
//  - 右侧：MarkdownEditorView（Obsidian 式预览/编辑，支持 [[双链]]，点击进入编辑、保存退出）。
//  - 搜索：调用 wiki_query.py，结果以只读形式显示在右侧。
//  - 双链点击：在右侧预览点击 [[页面]] 跳转到对应页面。
//

import Cocoa
import UniformTypeIdentifiers

private struct WikiPage {
    let name: String
    let type: String
    /// 别名集合（来自 markdown frontmatter `aliases:`），用于双链点击 fuzzy 查找。
    let aliases: [String]
    let file: String      // 相对 wiki_pages 的文件名；首页为 Wiki_首页.md
    let isHome: Bool
}

final class WikiViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - UI 组件
    private let searchField = NSSearchField()
    private let homeBtn = NSButton(title: "🏠 Wiki 首页", target: nil, action: nil)
    private let rebuildBtn = NSButton(title: "重建 Wiki", target: nil, action: nil)
    private let refreshBtn = NSButton(title: "刷新索引", target: nil, action: nil)
    private let folderBtn = NSButton(title: "打开文件夹", target: nil, action: nil)
    private let addBtn = NSButton(title: "＋ 新增", target: nil, action: nil)
    private let importBtn = NSButton(title: "📥 导入会议纪要", target: nil, action: nil)
    /// 「删除选中」按钮——多选模式下批量删除。
    private let deleteSelBtn = NSButton(title: "🗑 删除选中", target: nil, action: nil)

    private let tableView = NSTableView()
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))

    private let editor = MarkdownEditorView()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let progressIndicator = NSProgressIndicator()

    // MARK: - 状态
    private var pages: [WikiPage] = []
    private var selectedPage: WikiPage?
    private var busy = false
    private var showingSearch = false

    private var wikiDir: URL { AppConfig.shared.baseDir.appendingPathComponent("005_LLMWiKi") }
    private var wikiPagesDir: URL { wikiDir.appendingPathComponent("wiki_pages") }
    private var homeFile: URL { wikiDir.appendingPathComponent("Wiki_首页.md") }
    private var wikiScriptsDir: URL {
        // ① Bundle 内嵌 PythonEngine/005_LLMWiKi（v2.2.12+ 推荐路径，sandbox 友好）。
        // ② 回退到 `pipelineScript` 所在目录的 005_LLMWiKi/ 子目录（兼容开发期把脚本放在
        //    工程 PythonEngine/ 下、用户运行 `--query` 时按目录查找）。
        // 旧版走的是 `MM_BASE_DIR/005_LLMWiKi/`——但 sandbox App 启动后该路径在多数
        // 用户的 Downloads 外，已被 sandbox 拒；正确做法是把脚本拷到 bundle 内。
        if let r = AppConfig.bundledPythonEngineURL()?.appendingPathComponent("005_LLMWiKi"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("wiki_query.py").path) {
            return r
        }
        return AppConfig.shared.pipelineScript.deletingLastPathComponent()
            .appendingPathComponent("005_LLMWiKi")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        editor.delegate = self
        loadPages()
    }

    // MARK: - UI 布局
    private func setupUI() {
        let pad: CGFloat = 16

        searchField.placeholderString = "搜索 Wiki（本地检索，不出网）"
        searchField.recentsAutosaveName = "WikiSearchRecents"
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        [homeBtn, rebuildBtn, refreshBtn, folderBtn, addBtn, importBtn, deleteSelBtn].forEach { b in
            b.target = self
            b.bezelStyle = .rounded
        }
        homeBtn.action = #selector(goHome)
        rebuildBtn.action = #selector(rebuildWiki)
        refreshBtn.action = #selector(refreshIndex)
        folderBtn.action = #selector(openFolder)
        addBtn.action = #selector(addPage)
        importBtn.action = #selector(importMinutes)
        deleteSelBtn.action = #selector(deleteSelected)
        deleteSelBtn.isEnabled = false   // 有选中才启用

        let toolbar = NSStackView(views: [searchField, homeBtn, rebuildBtn, refreshBtn, folderBtn, addBtn, importBtn, deleteSelBtn])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.alignment = .centerY
        toolbar.distribution = .fill
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [homeBtn, rebuildBtn, refreshBtn, folderBtn, addBtn, importBtn, deleteSelBtn].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        nameColumn.title = "名称"
        nameColumn.width = 200
        typeColumn.title = "类型"
        typeColumn.width = 80
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(typeColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.allowsEmptySelection = true
        // ✅ 多选模型：⌘+点击切换、shift+点击范围、⌘+A 全选
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        // 右键菜单
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "删除", action: #selector(deleteSelected), keyEquivalent: ""))
        menu.items.last?.target = self
        tableView.menu = menu
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.documentView = tableView
        // 让 NSSplitView 用户可拖动调节宽度：
        //   1) 不再固定 320 宽（之前 widthAnchor=320 让 splitter 形同虚设）
        //   2) 给一个最小宽度 200（列表不至于被拖没）+ 弹性最大（跟随 split）
        //   3) 设一个起点宽度 320 让初次加载视觉稳定
        listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        listScroll.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        // 持久化用户的拖动位置（Xcode/macOS 原生支持）
        split.autosaveName = "WikiSplitPosition"
        // 让 split 在 stack 的垂直方向上"膨胀"——stack.distribution = .fill 默认选
        // hugging 最低的子视图作 gravity；这里把 split 设为最低，确保它吃满剩余空间。
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentHuggingPriority(.defaultLow, for: .horizontal)
        split.addSubview(listScroll)
        split.addSubview(editor)
        // 默认 NSSplitView 已允许用户拖动 divider；列表的 fixed-width 移除后即生效。

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [progressIndicator, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY

        let stack = NSStackView(views: [toolbar, split, statusRow])
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
            // split 横向拉满 stack（stack.alignment = .leading 不拉伸子视图，故需显式约束）
            split.widthAnchor.constraint(equalTo: stack.widthAnchor)
            // ❌ 不要把 split.heightAnchor 等于 stack.heightAnchor：
            //    stack 里装着 split 自己，会逼 toolbar / statusRow 高度归零，
            //    与它们的内禀高度 + Stack.Min(>=12) 互相冲突，必触发 Auto Layout 警告。
            //    改靠 split 的低 hugging 优先级 + stack.distribution=.fill 让 split 吃掉剩余空间。
        ])
    }

    // MARK: - 页面列表（Wiki 首页置顶）
    func reloadPages() { loadPages() }

    private func loadPages() {
        setBusy(true, status: "读取页面列表…")
        PipelineRunner.shared.run(script: nil, arguments: ["--list-wiki-pages"]) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            if let err = result.error {
                self.setBusy(false, status: "读取失败")
                let msg = "无法读取 Wiki 页面列表：\(err.localizedDescription)"
                // 授权失效（EPERM）时引导重设；其余错误（如 Python 缺失）走普通提示。
                if err.localizedDescription.contains("Operation not permitted") {
                    self.presentBaseDirAccessReset(message: msg)
                } else {
                    self.showAlert(msg)
                }
                return
            }
            guard let data = result.stdout.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                self.setBusy(false, status: "列表解析失败")
                return
            }
            var list: [WikiPage] = [
                WikiPage(name: "Wiki 首页", type: "home", aliases: [], file: "Wiki_首页.md", isHome: true)
            ]
            for d in arr {
                guard let name = d["name"] as? String,
                      let type = d["type"] as? String,
                      let file = d["file"] as? String else { continue }
                let aliases = (d["aliases"] as? [String]) ?? []
                list.append(WikiPage(name: name, type: type, aliases: aliases, file: file, isHome: false))
            }
            self.pages = list
            self.tableView.reloadData()
            self.setBusy(false, status: "共 \(self.pages.count) 个页面（首页已置顶）")
            // 默认选中 Wiki 首页
            self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            self.selectPage(self.pages[0])
        }
    }

    private func selectPage(_ page: WikiPage) {
        showingSearch = false
        selectedPage = page
        let url = page.isHome ? homeFile : wikiPagesDir.appendingPathComponent(page.file)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            editor.load(markdown: text, editable: true)
            statusLabel.stringValue = "\(page.name)（\(page.type)）"
        } else {
            editor.load(markdown: "（无法读取文件：\(url.path)）", editable: false)
            // v2.2.13：读取失败多半是 App 重启后丢失对 sandbox 外目录的授权（EPERM）。
            // 引导用户「重设工作目录…」重新授权，无需重启 App。
            presentBaseDirAccessReset(message: "无法读取文件：\(url.path)")
        }
        // 把现有页面名（含别名）推给编辑器，供双链自动完成 + 缺失页判定。
        editor.setWikiPages(pages.flatMap { [$0.name] + $0.aliases })
    }

    // MARK: - 搜索
    @objc private func runSearch() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        setBusy(true, status: "检索中…")
        let script = wikiScriptsDir.appendingPathComponent("wiki_query.py")
        PipelineRunner.shared.run(script: script, arguments: [q, "--top", "8"]) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            self.setBusy(false, status: "检索完成")
            if let err = result.error {
                self.editor.load(markdown: "检索失败：\(err.localizedDescription)", editable: false)
                return
            }
            self.showingSearch = true
            self.editor.load(markdown: result.stdout.isEmpty ? "（无结果）" : result.stdout, editable: false)
        }
    }

    // MARK: - 首页 / 重建 / 刷新 / 文件夹
    @objc private func goHome() {
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        selectPage(pages[0])
    }

    /// 供容器 / 菜单「重建 Wiki」调用（公开入口）。
    @objc func rebuildWikiFromExternal() { rebuildWiki() }

    @objc private func rebuildWiki() {
        setBusy(true, status: "重建 Wiki 首页（MOC）中…")
        // 仅重建 Wiki 首页导航页（--build-index）：纯本地、无出网、不触发 RAG 向量重建。
        // Wiki 页生成 与 RAG 索引是两回事——重建首页不会重跑 LLM 页面组织，也不会重建向量库。
        PipelineRunner.shared.run(script: nil, arguments: ["--build-index"]) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            self.setBusy(false, status: result.error == nil ? "首页已重建" : "重建失败")
            if let err = result.error { self.showAlert("Wiki 首页重建失败：\(err.localizedDescription)") }
            self.loadPages()
        }
    }

    @objc private func refreshIndex() {
        setBusy(true, status: "刷新索引…")
        PipelineRunner.shared.run(script: nil, arguments: ["--build-index"]) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            if let err = result.error {
                self.setBusy(false, status: "刷新失败")
                self.showAlert("刷新索引失败：\(err.localizedDescription)")
                return
            }
            PipelineRunner.shared.run(script: nil, arguments: ["--normalize-wiki"]) { _ in }
            completion: { [weak self] result2 in
                guard let self else { return }
                self.setBusy(false, status: result2.error == nil ? "索引已刷新" : "规范化失败")
                self.loadPages()
            }
        }
    }

    @objc private func openFolder() {
        if FileManager.default.fileExists(atPath: wikiPagesDir.path) {
            NSWorkspace.shared.open(wikiPagesDir)
        } else {
            showAlert("Wiki 页面目录不存在：\(wikiPagesDir.path)")
        }
    }

    // MARK: - 新增 / 保存
    @objc private func addPage() {
        WikiPropertySheet.present(initial: nil) { [weak self] spec in
            guard let self, let spec = spec else { return }
            self.submitPageCommand(arguments: [
                "--add-wiki-page",
                self.jsonString(spec.asDictForPython())
            ])
        }
    }

    /// 实现 SaveablePage：由容器顶部"保存"按钮触发 -> 走编辑器 requestSave -> delegate 回调。
    @objc func saveCurrent() {
        guard let page = selectedPage, !showingSearch else {
            if showingSearch { showAlert("当前为搜索结果，无法保存。请先在左侧选择页面。") }
            return
        }
        editor.requestSave()
        pendingSavePage = page
    }

    private var pendingSavePage: WikiPage?

    private func submitPageCommand(arguments: [String]) {
        setBusy(true, status: "写入中…")
        PipelineRunner.shared.run(script: nil, arguments: arguments) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            self.setBusy(false, status: result.error == nil ? "已保存" : "保存失败")
            if let err = result.error { self.showAlert("Wiki 页操作失败：\(err.localizedDescription)") }
            self.loadPages()
        }
    }

    // MARK: - 工具（setBusy 已移至下方，统一管理删除按钮等所有按钮的启用状态）

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .fragmentsAllowed),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func showAlert(_ msg: String) {
        AppAlert.show(message: "LLM Wiki", informative: msg, icon: .wiki)
    }

    // MARK: - 工作目录授权失效兜底（v2.2.13）

    /// 工作目录访问失败（EPERM）的统一兜底：弹提示并附「重设工作目录…」按钮，
    /// 用户重新用 NSOpenPanel 选目录后写 bookmark + 立即恢复授权 + 刷新，无需重启 App。
    private func presentBaseDirAccessReset(message: String) {
        let alert = NSAlert()
        alert.messageText = "工作目录无法访问"
        alert.informativeText = message +
            "\n\n如果是「Operation not permitted」类错误，通常是 App 重启后丢失了对该目录的授权。" +
            "点「重设工作目录…」重新选择同一目录即可恢复（无需重装）。"
        alert.alertStyle = .warning
        alert.icon = AppAlertIcon.warning.image
        alert.addButton(withTitle: "重设工作目录…")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            promptResetBaseDir()
        }
    }

    /// 弹 NSOpenPanel 重新选择工作目录，写入 bookmark 并立即恢复授权 + 刷新页面列表。
    private func promptResetBaseDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "重新选择工作目录（建议选回原来的目录）"
        panel.prompt = "设为工作目录"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            AppConfig.shared.setBaseDir(url)
            _ = AppConfig.shared.startAccessingBaseDir()
            self?.loadPages()
        }
    }

    // MARK: - NSTableViewDataSource / Delegate
    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < pages.count else { return nil }
        let page = pages[row]
        let value = (tableColumn == nameColumn) ? page.name : page.type
        let cell = NSTextField(labelWithString: value)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // 删除按钮：跟随选中数变化
        deleteSelBtn.isEnabled = (tableView.selectedRowIndexes.count > 0) && !busy
        // 仅当"恰好选中 1 行（导航式选择）"才跳转；
        // ⌘+点击/拖选扩展多选时保持当前页不变，避免误把用户刚翻到的页切走。
        let rows = tableView.selectedRowIndexes
        guard rows.count == 1, rows.first != nil, rows.first! < pages.count else { return }
        selectPage(pages[rows.first!])
        // 同步编辑视图的"可点击"焦点（仅当是单选）
        // 不需要额外操作：setBusy 由各处自行处理。
    }

    // MARK: - 全局 ⌘+Delete 键监听（仅本窗口激活时）批量删除选中
    private var keyMonitor: Any?

    override func viewWillAppear() {
        super.viewWillAppear()
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
                guard let self else { return e }
                let isCmdDelete = e.modifierFlags.contains(.command) &&
                                  (e.specialKey == .delete || e.keyCode == 51)
                if isCmdDelete && !self.busy && self.tableView.selectedRowIndexes.count > 0 {
                    DispatchQueue.main.async { self.deleteSelected() }
                    return nil
                }
                return e
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    // MARK: - 导入会议纪要（从原 GenerateViewController 迁过来）
    @objc private func importMinutes() {
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
        panel.prompt = "导入到 RAG"
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
                .appendingPathComponent("smm_rag_import_\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.createDirectory(at: stash, withIntermediateDirectories: true)
            for u in urls {
                let dest = stash.appendingPathComponent(u.lastPathComponent)
                try? FileManager.default.copyItem(at: u, to: dest)
            }
            targetPath = stash.path
        }
        setBusy(true, status: "正在导入文档…")
        statusLabel.stringValue = "正在导入…"
        progressIndicator.startAnimation(nil)
        importBtn.isEnabled = false

        PipelineRunner.shared.run(
            arguments: ["--json-log", "--import-docs", targetPath],
            progress: { [weak self] p in
                self?.statusLabel.stringValue = p.message
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.progressIndicator.stopAnimation(nil)
                self.importBtn.isEnabled = true
                self.setBusy(false, status: result.error == nil ? "导入完成" : "导入失败")
                if let err = result.error {
                    self.showAlert("导入失败：\(err.localizedDescription)")
                    return
                }
                if let j = result.finalJSON {
                    let total = j["total"] as? Int ?? 0
                    let suc   = (j["succeeded"] as? [String])?.count ?? 0
                    let fail  = (j["failed"] as? [String])?.count ?? 0
                    self.statusLabel.stringValue = "导入成功 \(suc)/\(total)，失败 \(fail)"
                }
            }
        )
    }

    // MARK: - 删除选中（多选 / ⌘+Backspace / 右键菜单）
    @objc private func deleteSelected() {
        let rows = tableView.selectedRowIndexes
        guard rows.count > 0, !busy else { return }
        let deleteable: [Int] = rows
            .filter { $0 > 0 && $0 < pages.count && !pages[$0].isHome }
            .sorted()
        if deleteable.isEmpty {
            showAlert("当前没有可删除的 Wiki 页（首页不可删）。")
            return
        }
        let names = deleteable.map { pages[$0].name }
        let alert = NSAlert()
        alert.messageText = "确认删除 \(deleteable.count) 个 Wiki 页？"
        alert.informativeText = "将永久删除以下页面（不可恢复）：\n• " + names.joined(separator: "\n• ")
        alert.alertStyle = .warning
        alert.icon = AppAlertIcon.warning.image
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setBusy(true, status: "删除 \(deleteable.count) 个页面…")
        let json = jsonString(["names": names])
        PipelineRunner.shared.run(script: nil, arguments: ["--delete-wiki-page", json]) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            self.setBusy(false, status: result.error == nil ? "已删除" : "删除失败")
            if let err = result.error { self.showAlert("删除失败：\(err.localizedDescription)") }
            self.loadPages()
        }
    }

    // MARK: - 工具
    private func setBusy(_ b: Bool, status: String) {
        busy = b
        statusLabel.stringValue = status
        [rebuildBtn, refreshBtn, folderBtn, addBtn, homeBtn, importBtn, deleteSelBtn, searchField].forEach { $0.isEnabled = !b }
        if !b {
            // 重新启用删除按钮的前提是已有选中
            deleteSelBtn.isEnabled = (tableView.selectedRowIndexes.count > 0)
        }
        if b { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
    }
}

// MARK: - 名称模糊匹配：半/全角括号与空格归一化，以便双链 `[[AMD (超威半导体)]]`
// 能命中存盘名 `AMD（超威半导体）.md` 之类的页面。
private func normalizeForWikiMatch(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    t = t.replacingOccurrences(of: "(", with: "（")
         .replacingOccurrences(of: ")", with: "）")
    t = t.replacingOccurrences(of: "　", with: " ")
    return t
}

/// 在页面集合中按名称或别名查找目标。
/// 匹配优先级：
///   ① 严格等值（不区分大小写）
///   ② 归一化等值（括号/空格，全/半角统一）
///   ③ 文件名匹配（页面文件名为 "X.md"，归一化去掉 .md 后比）
///   ④ aliases 命中（同样的等值/归一化两档）
///   ⑤ 前缀 fuzzy：剥掉 "ST (宪法半导体)" → "ST"，再按 canonical_name 前缀匹配
///      （应对 LLM 自动生成的双链里塞了描述性括号、但库里只存了短名的情况）
private func resolveWikiPage(in pages: [WikiPage], rawName: String) -> (Int, WikiPage)? {
    let target = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetN = normalizeForWikiMatch(target)
    guard !target.isEmpty else { return nil }

    // 1) 严格等值（不区分大小写）：canonical_name 完全相等
    if let i = pages.firstIndex(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) {
        return (i, pages[i])
    }
    // 2) 归一化等值：括号 / 全半角统一后再比
    if let i = pages.firstIndex(where: { normalizeForWikiMatch($0.name).caseInsensitiveCompare(targetN) == .orderedSame }) {
        return (i, pages[i])
    }
    // 3) 文件名匹配：把 ".md" 剥掉，再走一次严格 + 归一化（覆盖存盘名 "AMD（超威半导体）.md" 之类）
    if let i = pages.firstIndex(where: {
        let stem = $0.file.hasSuffix(".md") ? String($0.file.dropLast(3)) : $0.file
        return stem.caseInsensitiveCompare(target) == .orderedSame
            || normalizeForWikiMatch(stem).caseInsensitiveCompare(targetN) == .orderedSame
    }) {
        return (i, pages[i])
    }
    // 4) aliases 命中
    if let i = pages.firstIndex(where: { p in
        for a in p.aliases {
            if a.caseInsensitiveCompare(target) == .orderedSame { return true }
            if normalizeForWikiMatch(a).caseInsensitiveCompare(targetN) == .orderedSame { return true }
            let stem = a.hasSuffix(".md") ? String(a.dropLast(3)) : a
            if stem.caseInsensitiveCompare(target) == .orderedSame { return true }
        }
        return false
    }) {
        return (i, pages[i])
    }
    // 5) 前缀 fuzzy：剥掉 wikilink 里 "(" / "（" / 空格 之后的描述性尾巴，
    //    只保留短名再做一次严格/归一化匹配。处理 "[[ST (宪法半导体)]]" → "ST" 的常见情况。
    if let short = extractWikiShortName(target), short != target {
        let shortN = normalizeForWikiMatch(short)
        if let i = pages.firstIndex(where: {
            $0.name.caseInsensitiveCompare(short) == .orderedSame
                || normalizeForWikiMatch($0.name).caseInsensitiveCompare(shortN) == .orderedSame
        }) { return (i, pages[i]) }
        if let i = pages.firstIndex(where: { p in
            for a in p.aliases where a.caseInsensitiveCompare(short) == .orderedSame { return true }
            return false
        }) { return (i, pages[i]) }
    }
    return nil
}

/// 从 wikilink 目标名提取"短名"：取第一个括号 / 全角括号 / 空格 之前的部分。
/// 例：
///   "ST (宪法半导体)"            → "ST"
///   "ST（意法半导体）"            → "ST"
///   "AMD （超威半导体） 别名"     → "AMD"
///   "AMD"                       → "AMD"  （无变化，仍用于递归探测，避免误判）
///   "（待补全）"                  → nil  （纯括号描述没有短名）
private func extractWikiShortName(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    // 找到第一个 "(" / "（" / 全角空格 / 普通空格 的位置
    var cut = t.endIndex
    for (i, ch) in zip(t.indices, t) {
        if ch == "(" || ch == "（" || ch == " " || ch == "\t" || ch == "　" {
            cut = i
            break
        }
    }
    let head = String(t[t.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !head.isEmpty, head != t else { return nil }
    return head
}

// MARK: - MarkdownEditorViewDelegate / SaveablePage
extension WikiViewController: MarkdownEditorViewDelegate, SaveablePage {
    func markdownEditorDidRequestSave(_ editor: MarkdownEditorView, markdown: String) {
        guard let page = pendingSavePage else { return }
        pendingSavePage = nil
        let url = page.isHome ? homeFile : wikiPagesDir.appendingPathComponent(page.file)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            statusLabel.stringValue = "已保存 · \(page.name)"
        } catch {
            let msg = "保存失败：\(error.localizedDescription)"
            // 写入失败多半也是工作目录授权失效（EPERM），引导重设。
            if error.localizedDescription.contains("Operation not permitted")
                || error.localizedDescription.contains("permission") {
                presentBaseDirAccessReset(message: msg)
            } else {
                showAlert(msg)
            }
        }
    }

    func markdownEditorDidClickWikilink(_ editor: MarkdownEditorView, name: String) {
        if let (idx, page) = resolveWikiPage(in: pages, rawName: name) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            selectPage(page)
            return
        }
        // 没找到：礼貌给出 ⌘N 新建候选页的提示（带图标，避免破图）
        if AppAlert.show(
            message: "未找到 Wiki 页面",
            informative: "「\(name)」未在当前列表中。可能是尚未生成，或名称与现有页不一致。\n\n是否按此名称新建一个 Wiki 页？",
            icon: .question,
            style: .informational,
            buttons: ["新建", "取消"]
        ) == .alertFirstButtonReturn {
            // 预填：规范名 = [[双链]] 目标名，类型默认 person
            var prefill = WikiPageSpec(
                name: name, type: "person",
                aliases: [], tags: [], updated: "", backlinks: [],
                summary: "",
                company: "", jobTitle: "", role: "",
                companyType: "", industry: "", companyIntro: "",
                brand: "", model: "", category: "",
                functionDesc: "", status: "", replacement: ""
            )
            prefill.tags = ["wiki", "person"]
            WikiPropertySheet.present(initial: prefill) { [weak self] spec in
                guard let self, let spec = spec else { return }
                self.submitPageCommand(arguments: [
                    "--add-wiki-page",
                    self.jsonString(spec.asDictForPython())
                ])
            }
        }
    }

    /// 编辑器初始化时请求现有页面名列表（含别名），供双链自动完成 / 缺失页判定。
    func markdownEditorRequestsPageList(_ editor: MarkdownEditorView) -> [String] {
        Array(Set(pages.flatMap { [$0.name] + $0.aliases }))
    }

    /// 悬浮预览：返回目标页正文（已剥离 frontmatter）；页面不存在返回 nil。
    func markdownEditorPreviewForWikilink(_ editor: MarkdownEditorView, name: String) -> String? {
        guard let (_, page) = resolveWikiPage(in: pages, rawName: name) else { return nil }
        let url = page.isHome ? homeFile : wikiPagesDir.appendingPathComponent(page.file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // 剥离 YAML frontmatter，仅返回正文
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        var j = 1
        while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces) != "---" { j += 1 }
        guard j < lines.count else { return text }
        let body = lines.dropFirst(j + 1).joined(separator: "\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
    }

    // MARK: - frontmatter ↔ WikiPageSpec 互转（与 pipeline.py render_wiki_page 对齐）

    /// 从 markdown 中拆出 frontmatter 块，按 WikiPageSpec.asDictForPython() 的字段映射为 spec。
    static func parseWikiPageSpec(fromMarkdown md: String, fallbackName: String) -> WikiPageSpec {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else {
            return WikiPageSpec(
                name: fallbackName, type: "person",
                aliases: [], tags: [], updated: "", backlinks: [],
                summary: "",
                company: "", jobTitle: "", role: "",
                companyType: "", industry: "", companyIntro: "",
                brand: "", model: "", category: "",
                functionDesc: "", status: "", replacement: ""
            )
        }
        var j = 1
        while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces) != "---" { j += 1 }
        let fmLines: [String] = (j < lines.count) ? Array(lines[1..<j]) : []
        let dict = parseFrontmatterDict(fmLines)
        let t = (dict["type"] as? String ?? "person").lowercased()
        let name = (dict["canonical_name"] as? String) ?? fallbackName
        let aliases = (dict["aliases"] as? [String]) ?? []
        var tags = (dict["tags"] as? [String]) ?? []
        // 去掉内务标签，只保留人工标签给 UI 展示
        tags = tags.filter { $0 != "wiki" && $0 != t }
        let updated = (dict["updated"] as? String) ?? ""
        let backlinks = (dict["backlinks"] as? [String]) ?? []
        let summary = (dict["summary"] as? String) ?? ""
        let company = (dict["company"] as? String) ?? ""
        let jobTitle = (dict["title"] as? String) ?? ""
        let role = (dict["职能范围"] as? String) ?? ""
        let companyType = (dict["公司类型"] as? String) ?? ""
        let industry = (dict["所属行业"] as? String) ?? ""
        let companyIntro = (dict["公司简介"] as? String) ?? ""
        let brand = (dict["品牌"] as? String) ?? ""
        let model = (dict["具体型号"] as? String) ?? ""
        let category = (dict["类别"] as? String) ?? ""
        let functionDesc = (dict["功能简述"] as? String) ?? ""
        let status = (dict["状态"] as? String) ?? ""
        let replacement = (dict["替代料"] as? String) ?? ""
        return WikiPageSpec(
            name: name, type: t,
            aliases: aliases, tags: tags, updated: updated, backlinks: backlinks, summary: summary,
            company: company, jobTitle: jobTitle, role: role,
            companyType: companyType, industry: industry, companyIntro: companyIntro,
            brand: brand, model: model, category: category,
            functionDesc: functionDesc, status: status, replacement: replacement
        )
    }

    /// 极简 YAML frontmatter 解析器（仅支持 WikiPropertySheet 写回的格式）：
    ///   - key: scalar
    ///   - key: [a, b, c]           → [String]
    ///   - key:\n  - a\n  - b       → [String]
    /// 不依赖 YAML 库，避免 Swift 包管理负担。
    private static func parseFrontmatterDict(_ lines: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let m = line.range(of: #"^([A-Za-z0-9_一-鿿]+):\s*(.*)$"#, options: .regularExpression) {
                let key = String(line[line.startIndex..<line.index(m.lowerBound, offsetBy: 0)])
                // 取 : 前的部分（上面正则只匹配了首部，这里直接 split）
                if let colonIdx = line.firstIndex(of: ":") {
                    let k = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let v = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    if v.isEmpty {
                        // 块状列表
                        var items: [String] = []
                        var j = i + 1
                        while j < lines.count {
                            let s = lines[j]
                            if let sm = s.range(of: #"^\s+-\s+(.*)$"#, options: .regularExpression) {
                                let raw = String(s[s.startIndex..<sm.upperBound])
                                if let dashIdx = raw.firstIndex(of: "-") {
                                    items.append(String(raw[raw.index(after: dashIdx)...]).trimmingCharacters(in: .whitespaces))
                                }
                                j += 1
                            } else if s.trimmingCharacters(in: .whitespaces).isEmpty {
                                j += 1
                            } else { break }
                        }
                        out[k] = items
                        i = j
                    } else if v.hasPrefix("[") && v.hasSuffix("]") {
                        // 内联列表 [a, b, "c"]
                        let inner = String(v.dropFirst().dropLast())
                        let items = inner
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .map { stripQuoted($0) }
                            .filter { !$0.isEmpty }
                        out[k] = items
                        i += 1
                    } else {
                        out[k] = stripQuoted(v)
                        i += 1
                    }
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return out
    }

    private static func stripQuoted(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    /// 把 frontmatter dict + body 拼回 markdown。键值渲染顺序与 WikiPropertySheet.asDictForPython() 一致。
    static func composeMarkdown(frontmatterDict: [String: Any], body: String) -> String {
        let PLACEHOLDER = "（待补全）"
        let type = (frontmatterDict["type"] as? String ?? "person").lowercased()
        let name = (frontmatterDict["canonical_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let aliases = (frontmatterDict["aliases"] as? [String]) ?? []
        var fm: [String] = ["---", "type: \(type)", "canonical_name: \(name)"]
        fm.append(_blockList("aliases", aliases))
        switch type {
        case "person":
            fm.append("company: \((frontmatterDict["company"] as? String ?? "").trimmingCharacters(in: .whitespaces))")
            fm.append("title: \((frontmatterDict["title"] as? String ?? "").trimmingCharacters(in: .whitespaces))")
            fm.append("职能范围: \((frontmatterDict["职能范围"] as? String ?? "").trimmingCharacters(in: .whitespaces))")
        case "company":
            fm.append("公司类型: \((frontmatterDict["公司类型"] as? String ?? "").trimmingCharacters(in: .whitespaces))")
            fm.append("所属行业: \((frontmatterDict["所属行业"] as? String ?? "").trimmingCharacters(in: .whitespaces))")
            fm.append("公司简介: \((frontmatterDict["公司简介"] as? String ?? "").trimmingCharacters(in: .whitespaces))")
        case "chip":
            for k in ["品牌", "具体型号", "类别", "功能简述", "状态", "替代料"] {
                fm.append("\(k): \((frontmatterDict[k] as? String ?? "").trimmingCharacters(in: .whitespaces))")
            }
        default: break
        }
        let tags = (frontmatterDict["tags"] as? [String]) ?? []
        fm.append("tags: [" + tags.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
        fm.append("updated: \((frontmatterDict["updated"] as? String ?? "").trimmingCharacters(in: .whitespaces))")
        let backlinks = (frontmatterDict["backlinks"] as? [String]) ?? []
        if backlinks.isEmpty {
            fm.append("backlinks: []")
        } else {
            fm.append("backlinks:")
            for b in backlinks { fm.append("  - \(b)") }
        }
        // 兜底：把空白占位替换为 PLACEHOLDER（与 pipeline.py 渲染一致）
        for i in 0..<fm.count {
            if let colon = fm[i].firstIndex(of: ":") {
                let k = String(fm[i][fm[i].startIndex..<colon])
                let v = String(fm[i][fm[i].index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                // tags / updated / type / canonical_name / aliases / backlinks 不参与占位
                let skip = ["type", "canonical_name", "aliases", "tags", "updated", "backlinks", "中文名"]
                if !skip.contains(k) && (v.isEmpty || v == "[]") {
                    fm[i] = "\(k): \(PLACEHOLDER)"
                }
            }
        }
        fm.append("---")
        return fm.joined(separator: "\n") + "\n\n" + body
    }

    private static func _blockList(_ key: String, _ items: [String]) -> String {
        if items.isEmpty { return "\(key): []" }
        return key + ":\n" + items.map { "  - \($0)" }.joined(separator: "\n")
    }

    /// 从完整 markdown 中抠出 frontmatter 之后的正文；如果原本没有 frontmatter，返回全文。
    static func extractBody(afterFrontmatter md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else { return md }
        var j = 1
        while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces) != "---" { j += 1 }
        guard j < lines.count else { return md }
        return lines.dropFirst(j + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
