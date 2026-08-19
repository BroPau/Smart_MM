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

/// Wiki 页面（internal，供 WikiIndex 共享复用）。
struct WikiPage {
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
    private let homeBtn = NSButton(title: "🏠 WiKi 首页", target: nil, action: nil)
    private let rebuildBtn = NSButton(title: "重建 WiKi", target: nil, action: nil)
    private let refreshBtn = NSButton(title: "刷新索引", target: nil, action: nil)
    private let folderBtn = NSButton(title: "打开文件夹", target: nil, action: nil)
    private let addBtn = NSButton(title: "＋ 新增", target: nil, action: nil)
    /// 「删除选中」按钮——多选模式下批量删除。
    private let deleteSelBtn = NSButton(title: "🗑 删除选中", target: nil, action: nil)

    /// 右侧内容容器：托管 MarkdownEditorView（Wiki 首页与普通页均以 markdown 呈现，含分类表格 + 可点击双链）
    private let rightContainer = NSView()

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
    /// 由「会议纪要」页路由跳转时，若索引尚未加载则先加载，加载完成后用此名打开对应页。
    private var pendingOpenWikiName: String?
    /// 伴随 pendingOpenWikiName 的锚点（[[Page#Heading]] 的标题）。
    private var pendingOpenWikiAnchor: String?

    private var wikiDir: URL { AppConfig.shared.baseDir.appendingPathComponent("005_LLMWiKi") }
    private var wikiPagesDir: URL { wikiDir.appendingPathComponent("wiki_pages") }
    private var homeFile: URL { wikiDir.appendingPathComponent("WiKi首页.md") }
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
        // v2.2.33: 订阅全局双链跳转通知（来自 WikiPropertySheet 等任意 NSTextView click on link）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenWikiPageNotification(_:)),
            name: .openWikiPage, object: nil)
        loadPages()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleOpenWikiPageNotification(_ note: Notification) {
        guard let name = note.userInfo?["name"] as? String, !name.isEmpty else { return }
        let anchor = note.userInfo?["anchor"] as? String
        openWikiPageResolved(name, anchor: anchor)
    }

    // MARK: - UI 布局
    private func setupUI() {
        let pad: CGFloat = 16

        searchField.placeholderString = "搜索 WiKi（本地检索，不出网）"
        searchField.recentsAutosaveName = "WikiSearchRecents"
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        [homeBtn, rebuildBtn, refreshBtn, folderBtn, addBtn, deleteSelBtn].forEach { b in
            b.target = self
            b.bezelStyle = .rounded
        }
        homeBtn.action = #selector(goHome)
        rebuildBtn.action = #selector(rebuildWiki)
        refreshBtn.action = #selector(refreshIndex)
        folderBtn.action = #selector(openFolder)
        addBtn.action = #selector(addPage)
        deleteSelBtn.action = #selector(deleteSelected)
        deleteSelBtn.isEnabled = false   // 有选中才启用

        let toolbar = NSStackView(views: [searchField, homeBtn, rebuildBtn, refreshBtn, folderBtn, addBtn, deleteSelBtn])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.alignment = .centerY
        toolbar.distribution = .fill
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [homeBtn, rebuildBtn, refreshBtn, folderBtn, addBtn, deleteSelBtn].forEach {
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
        // 右侧内容容器：托管 MarkdownEditorView（Wiki 首页与普通页均以 markdown 呈现）
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
        split.addSubview(rightContainer)
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
                let msg = "无法读取 WiKi 页面列表：\(err.localizedDescription)"
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
                WikiPage(name: "WiKi 首页", type: "home", aliases: [], file: "WiKi首页.md", isHome: true)
            ]
            for d in arr {
                guard let name = d["name"] as? String,
                      let type = d["type"] as? String,
                      let file = d["file"] as? String else { continue }
                let aliases = (d["aliases"] as? [String]) ?? []
                list.append(WikiPage(name: name, type: type, aliases: aliases, file: file, isHome: false))
            }
            self.pages = list
            // 同步共享索引，供「会议纪要」页做名词联动 / 缺失页判定（无需再次跑子进程）
            WikiIndex.shared.sync(from: self.pages)
            self.tableView.reloadData()
            self.setBusy(false, status: "共 \(self.pages.count) 个页面（首页已置顶）")
            // 默认选中 Wiki 首页
            self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            self.selectPage(self.pages[0])
            // 若此前有「会议纪要」页路由过来的待打开页，加载完成后打开它
            if let pending = self.pendingOpenWikiName {
                self.pendingOpenWikiName = nil
                let anchor = self.pendingOpenWikiAnchor
                self.pendingOpenWikiAnchor = nil
                self.resolveOrPromptWikiPage(pending, anchor: anchor)
            }
        }
    }

    // MARK: - 反向链接（incoming）计算

    /// 计算「引用了当前页」的所有页面（incoming backlinks）：
    /// 扫描其他 Wiki 页（含首页）正文 + frontmatter 里的 [[当前页名]] / [[当前页别名]]
    /// （大小写不敏感，支持 [[Name|alias]]），返回这些页面的显示名，供 banner「反向链接」自动展示。
    private func computeIncomingBacklinks(for current: WikiPage) -> [String] {
        let targets = Set(([current.name] + current.aliases).map { $0.lowercased() })
        guard !targets.isEmpty else { return [] }
        let regex = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#, options: [])
        var found: [String] = []
        for page in pages where page.file != current.file {
            let url = page.isHome ? homeFile : wikiPagesDir.appendingPathComponent(page.file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            var hit = false
            regex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: text) else { return }
                let target = String(text[r]).trimmingCharacters(in: .whitespaces).lowercased()
                if targets.contains(target) { hit = true }
            }
            if hit { found.append(page.name) }
        }
        return found
    }

    private func selectPage(_ page: WikiPage) {
        showingSearch = false
        selectedPage = page
        // 首页：始终以 markdown 原文呈现（含分类表格 + 可点击双链），不再提供 NSTableView 表格模式
        if page.isHome {
            editor.isHidden = false
            if let text = try? String(contentsOf: homeFile, encoding: .utf8) {
                editor.load(markdown: text, editable: true, pageName: page.name)
                statusLabel.stringValue = "WiKi 首页"
            } else {
                editor.load(markdown: "（无法读取文件：\(homeFile.path)）", editable: false, pageName: "")
                presentBaseDirAccessReset(message: "无法读取文件：\(homeFile.path)")
            }
            editor.setWikiPages(pages.flatMap { [$0.name] + $0.aliases })
            // 推送 incoming 反向链接（被哪些页 [[引用]]），供 banner「反向链接」自动展示
            editor.setBacklinks(computeIncomingBacklinks(for: page))
            return
        }
        // 普通页面：显示编辑器
        editor.isHidden = false
        let url = wikiPagesDir.appendingPathComponent(page.file)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            editor.load(markdown: text, editable: true, pageName: page.name)
            statusLabel.stringValue = "\(page.name)（\(page.type.capitalized)）"
        } else {
            editor.load(markdown: "（无法读取文件：\(url.path)）", editable: false, pageName: "")
            // v2.2.13：读取失败多半是 App 重启后丢失对 sandbox 外目录的授权（EPERM）。
            // 引导用户「重设工作目录…」重新授权，无需重启 App。
            presentBaseDirAccessReset(message: "无法读取文件：\(url.path)")
        }
        // 把现有页面名（含别名）推给编辑器，供双链自动完成 + 缺失页判定。
        editor.setWikiPages(pages.flatMap { [$0.name] + $0.aliases })
        // 推送 incoming 反向链接（被哪些页 [[引用]]），供 banner「反向链接」自动展示
        editor.setBacklinks(computeIncomingBacklinks(for: page))
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
        setBusy(true, status: "重建 WiKi 首页（MOC）中…")
        // 仅重建 Wiki 首页导航页（--build-index）：纯本地、无出网、不触发 RAG 向量重建。
        // Wiki 页生成 与 RAG 索引是两回事——重建首页不会重跑 LLM 页面组织，也不会重建向量库。
        PipelineRunner.shared.run(script: nil, arguments: ["--build-index"]) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            self.setBusy(false, status: result.error == nil ? "首页已重建" : "重建失败")
            if let err = result.error { self.showAlert("WiKi 首页重建失败：\(err.localizedDescription)") }
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
            showAlert("WiKi 页面目录不存在：\(wikiPagesDir.path)")
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
            if let err = result.error { self.showAlert("WiKi 页操作失败：\(err.localizedDescription)") }
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
        AppAlert.show(message: "LLM WiKi", informative: msg, icon: .wiki)
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
    func numberOfRows(in tableView: NSTableView) -> Int {
        return pages.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < pages.count else { return nil }
        let page = pages[row]
        let value = (tableColumn == nameColumn) ? page.name : page.type.capitalized
        let cell = WikiRowCellView()
        cell.titleField.stringValue = value
        return cell
    }

    /// v2.2.40：返回圆角高亮的 WikiRowView，让 IMX93_RM 这种被选中行从直角蓝条改成圆角框。
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return WikiRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // 左侧页面列表：删除按钮跟随选中数变化
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

    // MARK: - 删除选中（多选 / ⌘+Backspace / 右键菜单）
    @objc private func deleteSelected() {
        let rows = tableView.selectedRowIndexes
        guard rows.count > 0, !busy else { return }
        let deleteable: [Int] = rows
            .filter { $0 > 0 && $0 < pages.count && !pages[$0].isHome }
            .sorted()
        if deleteable.isEmpty {
            showAlert("当前没有可删除的 WiKi 页（首页不可删）。")
            return
        }
        let names = deleteable.map { pages[$0].name }
        let alert = NSAlert()
        alert.messageText = "确认删除 \(deleteable.count) 个 WiKi 页？"
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
        [rebuildBtn, refreshBtn, folderBtn, addBtn, homeBtn, deleteSelBtn, searchField].forEach { $0.isEnabled = !b }
        if !b {
            // 重新启用删除按钮的前提是已有选中
            deleteSelBtn.isEnabled = (tableView.selectedRowIndexes.count > 0)
        }
        if b { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
    }
}

// MARK: - 名称模糊匹配：半/全角括号与空格归一化，以便双链 `[[AMD (超威半导体)]]`
// 能命中存盘名 `AMD（超威半导体）.md` 之类的页面。
func normalizeForWikiMatch(_ s: String) -> String {
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
func resolveWikiPage(in pages: [WikiPage], rawName: String) -> (Int, WikiPage)? {
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
func extractWikiShortName(_ s: String) -> String? {
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

    func markdownEditorDidClickWikilink(_ editor: MarkdownEditorView, name: String, anchor: String?) {
        resolveOrPromptWikiPage(name, anchor: anchor)
    }

    /// 解析并跳转，未命中则礼貌提示新建（供纪要页路由与本页点击复用）。anchor 为 [[Page#Heading]] 的标题锚点。
    private func resolveOrPromptWikiPage(_ name: String, anchor: String? = nil) {
        if let (idx, page) = resolveWikiPage(in: pages, rawName: name) {
            // 同页锚点（如正文里的 [[#Heading]]、或反向链接跳回当前页）：不重载当前页，
            // 直接滚动到目标标题，避免无谓刷新甚至丢失未保存的编辑。
            if let cur = selectedPage, cur.name == page.name {
                if let anchor = anchor, !anchor.isEmpty {
                    editor.scrollToAnchor(anchor)
                }
                return
            }
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            selectPage(page)
            if let anchor = anchor, !anchor.isEmpty {
                // 页面加载（含双链/表格渲染）为异步，略延迟后滚动到目标标题
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.editor.scrollToAnchor(anchor)
                }
            }
            return
        }
        // 没找到页、但带了锚点（例如旧数据里 [[#Heading]] 被当成页名）：尝试在当前页内滚动到该标题。
        if let anchor = anchor, !anchor.isEmpty {
            editor.scrollToAnchor(anchor)
            return
        }
        // 没找到：礼貌给出 ⌘N 新建候选页的提示（带图标，避免破图）
        if AppAlert.show(
            message: "未找到 WiKi 页面",
            informative: "「\(name)」未在当前列表中。可能是尚未生成，或名称与现有页不一致。\n\n是否按此名称新建一个 WiKi 页？",
            icon: .question,
            style: .informational,
            buttons: ["新建", "取消"]
        ) == .alertFirstButtonReturn {
            showCreateWikiPagePrompt(name)
        }
    }

    /// 未命中时弹出新建候选页表单（规范名 = name，类型默认 person）。
    private func showCreateWikiPagePrompt(_ name: String) {
        // 预填：规范名 = [[双链]] 目标名，类型默认 person
        var prefill = WikiPageSpec(
            name: name, type: "Person",
            aliases: [], tags: [], updated: "", backlinks: [],
            chineseName: "",
            company: "", jobTitle: "", role: "",
            companyType: "", industry: "", companyIntro: "",
            brand: "", model: "", category: "",
            functionDesc: "", status: "", replacement: ""
        )
        prefill.tags = ["wiki", "Person"]
        WikiPropertySheet.present(initial: prefill) { [weak self] spec in
            guard let self, let spec = spec else { return }
            self.submitPageCommand(arguments: [
                "--add-wiki-page",
                self.jsonString(spec.asDictForPython())
            ])
        }
    }

    /// 供容器（来自「会议纪要」页双链点击）调用：切到本页并打开对应 Wiki 页；
    /// 若索引尚未加载（用户还没打开过 Wiki 分页），则先加载再打开。
    func openWikiPageResolved(_ name: String, anchor: String? = nil) {
        if pages.isEmpty {
            pendingOpenWikiName = name
            pendingOpenWikiAnchor = anchor
            setBusy(true, status: "加载 WiKi 索引…")
            loadPages()
            return
        }
        resolveOrPromptWikiPage(name, anchor: anchor)
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
                name: fallbackName, type: "Person",
                aliases: [], tags: [], updated: "", backlinks: [],
                chineseName: "",
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
        let t = (dict["Type"] as? String) ?? "Person"
        let name = (dict["CanonicalName"] as? String) ?? fallbackName
        let aliases = (dict["Aliases"] as? [String]) ?? []
        var tags = (dict["Tags"] as? [String]) ?? []
        // 去掉内务标签，只保留人工标签给 UI 展示（类型 token 大小写不敏感）
        tags = tags.filter { $0.lowercased() != "wiki" && $0.lowercased() != t.lowercased() }
        let updated = (dict["Updated"] as? String) ?? ""
        let backlinks = (dict["Backlinks"] as? [String]) ?? []
        let chineseName = (dict["中文名"] as? String) ?? ""
        let company = (dict["Company"] as? String) ?? ""
        let jobTitle = (dict["Title"] as? String) ?? ""
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
            aliases: aliases, tags: tags, updated: updated, backlinks: backlinks, chineseName: chineseName,
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

// MARK: - 自定义行视图：圆角高亮 + 内边距
/// v2.2.40：默认 NSTableView 的选中框是直角的，左对齐，本类把它改成圆角蓝色框（圆角半径 6，左右各 8 上下各 3 的内边距让圆角露出来），同时让单元格文本居中——IMX93_RM 不再被贴左边。样式参考会议纪要里 DropView / MinuteRowView 同款 cornerRadius=10 的圆角观感。
final class WikiRowView: NSTableRowView {
    /// 选中背景的左右内边距（让圆角从行边缘往内收一点，否则 100% 填满看不到圆度）。
    private static let horizontalInset: CGFloat = 6
    /// 选中背景的上下内边距。
    private static let verticalInset: CGFloat = 2
    /// 圆角半径。匹配会议纪要卡片圆角观感，但行更扁所以略小一点。
    private static let cornerRadius: CGFloat = 6

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        // macOS 的 CGRect.insetBy 仅有 insetBy(dx:dy:)，手动算四角内缩矩形。
        let rect = NSRect(x: bounds.minX + Self.horizontalInset,
                          y: bounds.minY + Self.verticalInset,
                          width: bounds.width - Self.horizontalInset * 2,
                          height: bounds.height - Self.verticalInset * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        // 选中：accentColor 蓝色填充（与系统选中观感一致，但圆角）；非激活窗口用稍淡的描边色
        NSColor.controlAccentColor.setFill()
        path.fill()
    }
}

// MARK: - 自定义单元格：居中文本
/// v2.2.40：把 [[Page]] / [Type] 的 NSTextField 都居中，呼应圆角高亮框的视觉重心。
final class WikiRowCellView: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.font = NSFont.systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .center   // 居中
        titleField.textColor = .labelColor
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        textField = titleField
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
