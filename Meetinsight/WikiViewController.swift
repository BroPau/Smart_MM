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

final class WikiViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {

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

    /// v2.2.50: 存 split 引用，供 viewDidLayout 设初始分界位置
    private var wikiSplitView: NSSplitView?

    // MARK: - 状态
    private var pages: [WikiPage] = []
    private var selectedPage: WikiPage?
    private var busy = false
    private var showingSearch = false
    /// 由「会议纪要」页路由跳转时，若索引尚未加载则先加载，加载完成后用此名打开对应页。
    private var pendingOpenWikiName: String?
    /// 伴随 pendingOpenWikiName 的锚点（[[Page#Heading]] 的标题）。
    private var pendingOpenWikiAnchor: String?

    // MARK: - v2.2.55: 缓存 + 列宽/分界位置持久化
    /// 静默刷新时临时抑制 tableViewSelectionDidChange → 不触发 selectPage（避免打断编辑）。
    private var suppressSelectionChange = false
    /// 分界位置是否已初始化（防止 viewDidLayout 反复设默认值）。
    private var hasAppliedSplitPosition = false
    /// 列宽是否已从 UserDefaults 恢复（防止 setupUI 设默认值覆盖用户设置）。
    private var hasRestoredColumnWidths = false

    /// UserDefaults 键名常量。
    private enum PersistKey {
        static let nameColWidth = "WikiColumnNameWidth"
        static let typeColWidth = "WikiColumnTypeWidth"
        static let splitPosition = "WikiSplitPositionValue"
    }

    private var wikiDir: URL { AppConfig.shared.baseDir.appendingPathComponent("005_LLMWiKi") }
    private var wikiPagesDir: URL { wikiDir.appendingPathComponent("wiki_pages") }
    // ⚠️ 首页文件名必须与 pipeline.Config.WIKI_MOC 完全一致（磁盘真实文件 = `Wiki_首页.md`，
    // 由 --build-index / _auto_rebuild_wiki 生成）。切勿改成 `WiKi首页.md`——那个名字的文件
    // 从不被创建，会导致首页加载失败（「无法读取文件」）。显示名仍可保持「WiKi 首页」。
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
        // v2.2.33: 订阅全局双链跳转通知（来自 WikiPropertySheet 等任意 NSTextView click on link）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenWikiPageNotification(_:)),
            name: .openWikiPage, object: nil)
        // v2.2.55: 监听列宽变化——主动持久化到 UserDefaults
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: tableView)

        // v2.2.55: 缓存优先 + 后台静默刷新
        if let cache = WikiCache.shared.loadPages() {
            // 有缓存：直接渲染（秒开，不跑 Python）
            self.pages = cache.pages
            WikiIndex.shared.sync(from: self.pages)
            self.autoSizeSidebarColumnsIfNeeded()  // v2.2.76
            self.tableView.reloadData()
            // 选中缓存中记录的页面（或默认首页）
            var row = 0
            if let name = cache.selectedPageName,
               let idx = self.pages.firstIndex(where: { $0.name == name }) {
                row = idx
            }
            self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self.selectPage(self.pages[row])
            self.setBusy(false, status: "已加载缓存（后台刷新中…）")
            // 后台异步刷新（静默，用户无感知）
            refreshPagesFromPipeline(silent: true)
        } else {
            // 无缓存（首次打开）：正常加载
            loadPages()
        }
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
        // v2.2.56: 搜索栏宽度跟随左侧面板（不再固定宽度）

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

        // v2.2.56: 按钮栏（放在右侧面板顶部，与编辑器左对齐）
        let buttonToolbar = NSStackView(views: [homeBtn, rebuildBtn, refreshBtn, folderBtn, addBtn, deleteSelBtn])
        buttonToolbar.orientation = .horizontal
        buttonToolbar.spacing = 10
        buttonToolbar.alignment = .centerY
        buttonToolbar.distribution = .fill
        buttonToolbar.translatesAutoresizingMaskIntoConstraints = false
        [homeBtn, rebuildBtn, refreshBtn, folderBtn, addBtn, deleteSelBtn].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        nameColumn.title = "名称"
        nameColumn.minWidth = 160
        nameColumn.maxWidth = 560
        typeColumn.title = "类型"
        typeColumn.minWidth = 80
        typeColumn.maxWidth = 220
        // v2.2.76：有持久化宽度则恢复；否则先放 minWidth 占位，autoSizeSidebarColumnsIfNeeded() 在页加载完后按内容覆盖
        nameColumn.width = UserDefaults.standard.object(forKey: PersistKey.nameColWidth) as? CGFloat ?? nameColumn.minWidth
        typeColumn.width = UserDefaults.standard.object(forKey: PersistKey.typeColWidth) as? CGFloat ?? typeColumn.minWidth
        hasRestoredColumnWidths = true
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(typeColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.allowsEmptySelection = true
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
        listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        listScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 800).isActive = true

        // v2.2.56: 左侧面板 = 搜索栏 + 列表（搜索栏与列表同宽，跟随 split 分界线）
        let leftPane = NSView()
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(searchField)
        leftPane.addSubview(listScroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: leftPane.topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
        ])

        // v2.2.56: 右侧面板 = 按钮栏 + 编辑器（按钮与编辑器左对齐）
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
        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(buttonToolbar)
        rightPane.addSubview(rightContainer)
        NSLayoutConstraint.activate([
            buttonToolbar.topAnchor.constraint(equalTo: rightPane.topAnchor),
            buttonToolbar.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            rightContainer.topAnchor.constraint(equalTo: buttonToolbar.bottomAnchor, constant: 8),
            rightContainer.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            rightContainer.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            rightContainer.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
        ])

        let split = NSSplitView()
        wikiSplitView = split
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentHuggingPriority(.defaultLow, for: .horizontal)
        split.addSubview(leftPane)
        split.addSubview(rightPane)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [progressIndicator, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY

        let stack = NSStackView(views: [split, statusRow])
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

    // MARK: - 页面列表（Wiki 首页置顶）
    func reloadPages() { loadPages() }

    /// 公开入口——非静默加载（显示 busy 状态，完成后选中首页）。
    func loadPages() {
        refreshPagesFromPipeline(silent: false)
    }

    /// v2.2.55: 从 pipeline 读取页面列表。
    /// - silent=true：不显示 busy、不切换选中页、不打断编辑器，仅更新列表 + 写缓存（后台静默刷新）。
    /// - silent=false：显示 busy、完成后选中首页、处理 pendingOpenWikiName（等同原 loadPages）。
    /// - reselectFile（v2.2.60）：非静默时若给出文件名，完成后改选中该文件对应页（用于编辑改名后
    ///   跟随到新页），而非默认回首页；命中不到再退回首页。
    private func refreshPagesFromPipeline(silent: Bool, reselectFile: String? = nil, completion: (() -> Void)? = nil) {
        if !silent {
            setBusy(true, status: "读取页面列表…")
        }
        PipelineRunner.shared.run(script: nil, arguments: ["--list-wiki-pages"]) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            if let err = result.error {
                if !silent {
                    self.setBusy(false, status: "读取失败")
                    let msg = "无法读取 WiKi 页面列表：\(err.localizedDescription)"
                    if err.localizedDescription.contains("Operation not permitted") {
                        self.presentBaseDirAccessReset(message: msg)
                    } else {
                        self.showAlert(msg)
                    }
                }
                return
            }
            guard let data = result.stdout.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                if !silent { self.setBusy(false, status: "列表解析失败") }
                return
            }
            var list: [WikiPage] = [
                // file 必须与 pipeline 生成的 MOC 文件名一致（Wiki_首页.md），见 homeFile 上的契约注释
                WikiPage(name: "WiKi 首页", type: "home", aliases: [], file: "Wiki_首页.md", isHome: true)
            ]
            for d in arr {
                guard let name = d["name"] as? String,
                      let type = d["type"] as? String,
                      let file = d["file"] as? String else { continue }
                let aliases = (d["aliases"] as? [String]) ?? []
                list.append(WikiPage(name: name, type: type, aliases: aliases, file: file, isHome: false))
            }
            // 记录当前选中页名（用于缓存 + 静默刷新后恢复选中）
            let currentName = self.selectedPage?.name
            self.pages = list
            // v2.2.81：构建双链/反链索引缓存（只在此处重建一次，切页不再重读全部文件）
            self.buildLinkIndex()
            // 同步共享索引，供「会议纪要」页做名词联动 / 缺失页判定
            WikiIndex.shared.sync(from: self.pages)
            self.autoSizeSidebarColumnsIfNeeded()  // v2.2.76
            self.tableView.reloadData()
            // 写缓存
            WikiCache.shared.savePages(list, selectedPageName: currentName)

            if silent {
                // 静默刷新：恢复选中行但不触发 selectPage（避免打断编辑器）
                self.suppressSelectionChange = true
                var row = 0
                if let name = currentName,
                   let idx = list.firstIndex(where: { $0.name == name }) {
                    row = idx
                }
                self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.suppressSelectionChange = false
                self.deleteSelBtn.isEnabled = (self.tableView.selectedRowIndexes.count > 0) && !self.busy
                self.statusLabel.stringValue = "共 \(list.count) 个页面（后台已刷新）"
            } else {
                // 非静默：选中目标页（默认首页）+ 加载内容 + 处理 pending
                self.setBusy(false, status: "共 \(self.pages.count) 个页面（首页已置顶）")
                var row = 0
                if let f = reselectFile, let idx = list.firstIndex(where: { $0.file == f }) {
                    row = idx
                }
                self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.selectPage(self.pages[row])
                // 若此前有「会议纪要」页路由过来的待打开页，加载完成后打开它
                if let pending = self.pendingOpenWikiName {
                    self.pendingOpenWikiName = nil
                    let anchor = self.pendingOpenWikiAnchor
                    self.pendingOpenWikiAnchor = nil
                    self.resolveOrPromptWikiPage(pending, anchor: anchor)
                }
            }
            completion?()
        }
    }

    // MARK: - 引用此页面的页面明细（用于嵌入表格）

    /// v2.2.67：扫描其他页面正文里 [[引用了本页]] 的页面，返回其「名称 + 类型 + 关键属性」明细，
    /// 供当前页正文末尾渲染可点击回跳的嵌入表格。适用于所有类型（不再局限于 Company）。
    private func referencesToThis(for page: WikiPage) -> [[String: Any]] {
        let targets = Set(([page.name] + page.aliases).map { $0.lowercased() })
        guard !targets.isEmpty else { return [] }
        var out: [[String: Any]] = []
        var seen = Set<String>()
        // wiki 页入链：仅做内存集合命中，不再重读每个文件全文（内存优化，v2.2.81）
        for p in pages where p.file != page.file {
            guard let keys = linkIndex.outgoingByFile[p.file], !keys.isDisjoint(with: targets) else { continue }
            let key = p.name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            var dict: [String: Any] = ["name": p.name, "type": p.type]
            if let meta = linkIndex.metaByFile[p.file], !meta.fields.isEmpty {
                dict["fields"] = meta.fields
            }
            out.append(dict)
        }
        // 会议纪要入链：同样走索引，不重读纪要全文（v2.2.81）
        for (name, keys) in linkIndex.minuteOutgoing where !keys.isDisjoint(with: targets) {
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(["name": name, "type": "会议纪要"])
        }
        return out
    }

    /// v2.2.75：把 [[目标]] 里的原始文本归一为比较键 —— 去掉 #区块 锚点、去空白、小写。
    /// （不做这一步，[[格力电器#三、四大业务板块]] 这类块级引用会算不进反向链接。）
    static func linkTargetKey(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let h = s.firstIndex(of: "#") { s = String(s[s.startIndex..<h]) }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// v2.2.68：扫描「当前页正文里 [[链接]] 到的页面」（outgoing 出链），返回其「名称 + 类型 + 关键属性」明细，
    /// 供当前页正文末尾「双链关系」表格的出链区渲染。适用于所有类型。
    private func referencesFromThis(for page: WikiPage) -> [[String: Any]] {
        let url = page.isHome ? homeFile : wikiPagesDir.appendingPathComponent(page.file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let regex = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#, options: [])
        var rawTargets: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        regex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: text) else { return }
            // v2.2.75：出链同样先剥掉 #区块 锚点，否则 [[页面#区块]] 解析不到目标页
            var t = String(text[r]).trimmingCharacters(in: .whitespaces)
            if let h = t.firstIndex(of: "#") { t = String(t[t.startIndex..<h]).trimmingCharacters(in: .whitespaces) }
            if !t.isEmpty { rawTargets.append(t) }
        }
        var out: [[String: Any]] = []
        var seen = Set<String>()
        for raw in rawTargets {
            guard let (_, p) = resolveWikiPage(in: pages, rawName: raw) else { continue }
            let key = p.name.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            // 直接读索引里的元信息，避免为每个出链目标再读一次全文（内存优化，v2.2.81）
            var dict: [String: Any] = ["name": p.name, "type": p.type]
            if let meta = linkIndex.metaByFile[p.file], !meta.fields.isEmpty {
                dict["fields"] = meta.fields
            }
            out.append(dict)
        }
        return out
    }

    /// v2.2.67：按类型枚举「引用此页面的页面」表格应展示的 frontmatter 字段键。
    /// 人员(Person) 重点展示职位/电话/电子邮箱等；其余类型由前端约定择优展示。
    private static func referenceWantedKeys(for type: String) -> [String] {
        switch type {
        case "person":  return ["company", "title", "phone", "email", "department"]
        case "company": return ["所属行业", "官网", "联系人"]
        case "chip":    return ["品牌", "具体型号", "厂商", "工艺节点"]
        case "project": return ["概要", "summary", "status", "负责人", "时间"]
        case "topic":   return ["分类", "领域"]
        case "method":  return ["类别", "应用"]
        default:        return []
        }
    }

    /// 轻量 frontmatter 标量解析（仅需提取少数展示字段，不处理列表/多行）。
    private func parseFrontmatterScalar(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        var i = 1
        while i < lines.count {
            let s = lines[i]
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            // 列表项（以 "  - " 开头）跳过；仅取顶层「key: value」
            if s.hasPrefix(" ") || s.hasPrefix("\t") { i += 1; continue }
            if let colon = s.range(of: ":") {
                let k = String(s[s.startIndex..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
                let v = String(s[s.index(after: colon.lowerBound)...]).trimmingCharacters(in: .whitespaces)
                if !k.isEmpty, !v.isEmpty, !v.hasPrefix("-") {
                    result[k] = v
                }
            }
            i += 1
        }
        return result
    }

    private static func backlinkFieldLabel(_ key: String) -> String {
        switch key {
        case "company": return "公司"
        case "title": return "职位"
        case "phone": return "电话"
        case "email": return "电子邮箱"
        case "department": return "部门"
        case "品牌": return "品牌"
        case "具体型号": return "型号"
        case "厂商": return "厂商"
        case "工艺节点": return "工艺节点"
        case "所属行业": return "行业"
        case "官网": return "官网"
        case "联系人": return "联系人"
        case "概要", "summary": return "概要"
        case "status": return "状态"
        case "负责人": return "负责人"
        case "时间": return "时间"
        case "分类": return "分类"
        case "领域": return "领域"
        case "类别": return "类别"
        case "应用": return "应用"
        case "职能范围": return "职能范围"
        default: return key
        }
    }

    private func selectPage(_ page: WikiPage) {
        // v2.2.81：离开上一页前，用其最新落盘内容增量刷新索引（只重读 1 个文件，远比旧逻辑重读全部页面便宜），
        // 保证导航过程中出链/入链索引始终新鲜，无需每次切页都全量重建。
        if let prev = selectedPage, prev.file != page.file {
            updateLinkIndex(for: prev)
        }
        // v2.2.65：切页前若当前页有未保存改动，先自动保存（无需手动点保存键）。
        // 此时 selectedPage 仍是上一页（尚未被本函数改写），editor 仍呈现上一页内容，
        // saveCurrent() 会经 editorBridge 把上一页正文回传落盘。
        if !showingSearch, let current = selectedPage, editor.isDirty {
            saveCurrent()
        }
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
        // v2.2.68：下发「本页引用的页面」（出链）+「引用本页的页面」（入链）明细，渲染正文末尾双向双链表格
        let outgoing = referencesFromThis(for: page)
        let incoming = referencesToThis(for: page)
        currentOutgoing = outgoing
        currentIncoming = incoming
        editor.setPageReferencesOut(outgoing)
        editor.setPageReferences(incoming)
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
        // v2.2.68：下发「本页引用的页面」（出链）+「引用本页的页面」（入链）明细，渲染正文末尾双向双链表格
        let outgoing = referencesFromThis(for: page)
        let incoming = referencesToThis(for: page)
        currentOutgoing = outgoing
        currentIncoming = incoming
        editor.setPageReferencesOut(outgoing)
        editor.setPageReferences(incoming)
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

    // v2.2.68：缓存当前页的「出链 / 入链」明细，供表格「添加双链」时就地刷新（无需整页重载）
    private var currentOutgoing: [[String: Any]] = []
    private var currentIncoming: [[String: Any]] = []

    // MARK: - v2.2.81：双链/反链索引缓存（内存优化）
    // 旧逻辑：每次切页都 String(contentsOf:) 重读全部 209 个 wiki 页 + 全部会议纪要全文 → 瞬时数百 MB 分配 + 卡顿。
    // 现改为「构建一次索引，切页仅做内存集合命中」：索引存每个页面的出链目标键集合 + 元信息（名称/别名/类型/展示字段）。
    private struct WikiLinkIndex {
        var outgoingByFile: [String: Set<String>] = [:]   // wiki 页 file -> 出链目标键集合（lowercased，已剥 #锚点）
        var metaByFile: [String: PageMeta] = [:]           // wiki 页 file -> 元信息（含按类型算好的展示字段）
        var minuteOutgoing: [String: Set<String>] = [:]    // 纪要文件名(去扩展名) -> 出链目标键集合
    }
    private struct PageMeta {
        let name: String
        let aliases: [String]
        let type: String
        let fields: [[String: String]]
    }
    private var linkIndex = WikiLinkIndex()

    /// 全量重建索引（在 refreshPagesFromPipeline 内、pages 已更新后调用一次）。
    private func buildLinkIndex() {
        var idx = WikiLinkIndex()
        let regex = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#, options: [])
        for p in pages {
            updateIndex(&idx, for: p, regex: regex)
        }
        let dir = AppConfig.shared.baseDir.appendingPathComponent("003_Meeting_Minutes")
        if FileManager.default.fileExists(atPath: dir.path),
           let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                guard url.pathExtension.lowercased() == "md" else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                idx.minuteOutgoing[name] = Self.extractLinkKeys(text, regex: regex)
            }
        }
        linkIndex = idx
    }

    /// 离开某页时增量刷新其索引条目（只重读 1 个文件，远比旧逻辑重读全部页面便宜）。
    private func updateLinkIndex(for page: WikiPage) {
        let regex = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#, options: [])
        var idx = linkIndex
        updateIndex(&idx, for: page, regex: regex)
        linkIndex = idx
    }

    private func updateIndex(_ idx: inout WikiLinkIndex, for page: WikiPage, regex: NSRegularExpression?) {
        let url = page.isHome ? homeFile : wikiPagesDir.appendingPathComponent(page.file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        idx.outgoingByFile[page.file] = Self.extractLinkKeys(text, regex: regex)
        let fm = parseFrontmatterScalar(text)
        idx.metaByFile[page.file] = PageMeta(
            name: page.name, aliases: page.aliases, type: page.type,
            fields: Self.fieldsFor(type: page.type, fm: fm)
        )
    }

    private static func extractLinkKeys(_ text: String, regex: NSRegularExpression?) -> Set<String> {
        var set = Set<String>()
        guard let regex else { return set }
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: text) else { return }
            set.insert(Self.linkTargetKey(String(text[r])))
        }
        return set
    }

    private static func fieldsFor(type: String, fm: [String: String]) -> [[String: String]] {
        let t = type.lowercased()
        let wanted = referenceWantedKeys(for: t)
        var fields: [[String: String]] = []
        for w in wanted {
            if let v = fm[w], !v.isEmpty {
                fields.append(["label": backlinkFieldLabel(w), "value": v])
            }
        }
        return fields
    }

    private func submitPageCommand(arguments: [String]) {
        setBusy(true, status: "写入中…")
        PipelineRunner.shared.run(script: nil, arguments: arguments) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            // v2.2.56：pipeline 的业务错误（重名、type 不支持等）写在 stdout 的 "ERR …" 并以退出码 2 退出，
            // 只读 error.localizedDescription 会退化成「退出码 2」，用户无从判断原因。
            let reason = Self.pipelineErrorReason(result.stdout) ?? result.error?.localizedDescription
            self.setBusy(false, status: reason == nil ? "已保存" : "保存失败")
            if let reason = reason { self.showAlert("WiKi 页操作失败：\(reason)") }
            self.loadPages()
        }
    }

    // MARK: - v2.2.68：双链表格「添加双链」辅助

    /// 按名称解析既有页；不存在则按名称推断类型并新建一个最小 WiKi 页（仅 frontmatter，正文为空），
    /// 完成后回调返回该页。新建走与「新建 WiKi 页」对话框相同的 --add-wiki-page 契约。
    private func resolveOrCreatePage(named raw: String, completion: @escaping (WikiPage?) -> Void) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let (_, p) = resolveWikiPage(in: pages, rawName: name) {
            completion(p)
            return
        }
        let type = Self.inferType(for: name)
        let spec = WikiPageSpec(
            name: name, type: type, aliases: [], tags: ["wiki", type],
            updated: "", backlinks: [],
            chineseName: "", company: "", jobTitle: "", role: "",
            companyType: "", industry: "", companyIntro: "",
            brand: "", model: "", category: "", functionDesc: "", status: "", replacement: ""
        )
        createWikiPage(spec) { page in
            completion(page)
        }
    }

    /// 调 pipeline --add-wiki-page 新建页面；成功后静默刷新页面列表并回调（回调内可立即拿到新页）。
    private func createWikiPage(_ spec: WikiPageSpec, completion: @escaping (WikiPage?) -> Void) {
        setBusy(true, status: "新建页面中…")
        PipelineRunner.shared.run(script: nil, arguments: ["--add-wiki-page", jsonString(spec.asDictForPython())]) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            let reason = Self.pipelineErrorReason(result.stdout) ?? result.error?.localizedDescription
            self.setBusy(false, status: reason == nil ? "已新建" : "新建失败")
            if let reason = reason {
                self.showAlert("新建 WiKi 页失败：\(reason)")
                completion(nil)
                return
            }
            self.refreshPagesFromPipeline(silent: true) {
                completion(resolveWikiPage(in: self.pages, rawName: spec.name).map { $0.1 })
            }
        }
    }

    /// 在目标页正文末尾追加一行 [[linkName]] 双链（直接写文件，目标页当前未打开，安全）。
    /// 仅追加正文，不动 frontmatter，因此不影响脱敏词典同步；链接会即时计入「引用本页」扫描。
    private func appendLinkToPageBody(_ file: String, linkName: String, isHome: Bool) {
        let url = isHome ? homeFile : wikiPagesDir.appendingPathComponent(file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let appended = text + "\n\n[[" + linkName + "]]\n"
        try? appended.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 按页面名粗推断类型（新建双链目标页时用）。命中公司/芯片特征词 → 对应类型，否则默认 Topic。
    private static func inferType(for name: String) -> String {
        let n = name.lowercased()
        let companyHits = ["公司", "科技", "股份", "集团", "有限", "inc", "corp", "corporation", "ltd", "llc", "co."]
        let chipHits = ["芯片", "型号", "处理器", "soc", "chip", "mcu", "cpu", "gpu"]
        if companyHits.contains(where: { n.contains($0) }) { return "Company" }
        if chipHits.contains(where: { n.contains($0) }) { return "Chip" }
        return "Topic"
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
        // v2.2.55: 静默刷新时临时抑制 selectPage（避免打断编辑器）
        if suppressSelectionChange { return }
        // 仅当"恰好选中 1 行（导航式选择）"才跳转；
        // ⌘+点击/拖选扩展多选时保持当前页不变，避免误把用户刚翻到的页切走。
        let rows = tableView.selectedRowIndexes
        guard rows.count == 1, rows.first != nil, rows.first! < pages.count else { return }
        selectPage(pages[rows.first!])
        // 同步编辑视图的"可点击"焦点（仅当是单选）
        // 不需要额外操作：setBusy 由各处自行处理。
    }

    // MARK: - v2.2.55: 首次布局设默认分界位置（从 UserDefaults 恢复）
    override func viewDidLayout() {
        super.viewDidLayout()
        if !hasAppliedSplitPosition {
            hasAppliedSplitPosition = true
            // 从 UserDefaults 读取用户上次设定的分界位置；无记录用默认 440
            let pos = UserDefaults.standard.object(forKey: PersistKey.splitPosition) as? CGFloat ?? 440
            wikiSplitView?.setPosition(pos, ofDividerAt: 0)
        }
    }

    // MARK: - v2.2.55: 列宽 + 分界位置主动持久化

    /// 列宽变化时保存到 UserDefaults。
    @objc private func columnDidResize(_ note: Notification) {
        guard hasRestoredColumnWidths else { return }
        // NSTableView.columnDidResizeNotification 的 userInfo 含 NSTableColumn
        if let col = note.userInfo?["NSTableColumn"] as? NSTableColumn {
            if col.identifier.rawValue == "name" {
                UserDefaults.standard.set(col.width, forKey: PersistKey.nameColWidth)
            } else if col.identifier.rawValue == "type" {
                UserDefaults.standard.set(col.width, forKey: PersistKey.typeColWidth)
            }
        }
    }

    // MARK: - v2.2.76：首次打开 / 无持久化列宽时按内容计算最小列宽
    private func autoSizeSidebarColumnsIfNeeded() {
        let hasName = UserDefaults.standard.object(forKey: PersistKey.nameColWidth) != nil
        let hasType = UserDefaults.standard.object(forKey: PersistKey.typeColWidth) != nil
        guard !hasName && !hasType else { return }  // 用户已拖拽自定义过列宽，尊重之
        let cellFont = NSFont.systemFont(ofSize: 13)
        let headerFont = NSFont.boldSystemFont(ofSize: 13)
        let pad: CGFloat = 28  // cell 内边距 + 文本框间距
        var maxName: CGFloat = 0
        var maxType: CGFloat = 0
        for p in pages {
            let n = (p.name as NSString).size(withAttributes: [.font: cellFont]).width
            if n > maxName { maxName = n }
            let t = (p.type.capitalized as NSString).size(withAttributes: [.font: cellFont]).width
            if t > maxType { maxType = t }
        }
        let headerName = ("名称" as NSString).size(withAttributes: [.font: headerFont]).width
        let headerType = ("类型" as NSString).size(withAttributes: [.font: headerFont]).width
        let nameW = min(max(maxName, headerName) + pad, nameColumn.maxWidth)
        let typeW = min(max(maxType, headerType) + pad, typeColumn.maxWidth)
        nameColumn.width = max(nameW, nameColumn.minWidth)
        typeColumn.width = max(typeW, typeColumn.minWidth)
    }

    // MARK: - NSSplitViewDelegate

    /// 用户拖动分界线后保存位置到 UserDefaults。
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard hasAppliedSplitPosition else { return }
        // 防止初始布局触发的 resize 覆盖用户设定
        guard let split = notification.object as? NSSplitView, split.subviews.count >= 2 else { return }
        let pos = split.subviews[0].frame.width
        UserDefaults.standard.set(pos, forKey: PersistKey.splitPosition)
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
        // WiKi 首页（Wiki_首页.md，由 --build-index 生成）是导航页，没有实体 frontmatter
        // （无 Type / CanonicalName），不适用 --edit-wiki-page 契约，保持直写（homeFile）。
        if page.isHome {
            do {
                try markdown.write(to: homeFile, atomically: true, encoding: .utf8)
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
            return
        }
        // 实体页：统一走 pipeline.py --edit-wiki-page（v2.2.60 起 Swift 侧改为唯一写入口；pipeline 侧自 v2.2.56 已支持）。
        // 此前直写文件会绕过 _sync_wiki_to_dicts —— 改了别名/公司不进脱敏词典、WiKi 首页也不刷新，
        // 造成「App 写的页」与「pipeline 认的实体」双轨漂移。改为传整篇 markdown，
        // 由 pipeline 解析 frontmatter 重渲染 + 原样保留正文。
        saveEntityPageViaPipeline(page: page, markdown: markdown)
    }

    /// v2.2.60：实体 Wiki 页保存 —— 调 `--edit-wiki-page` 的 markdown 形态
    /// （payload = `{original_name, markdown}`，见 pipeline.py `_spec_from_markdown`）。
    /// 失败时【绝不】刷新列表或重载编辑器：用户正文原样留在编辑器里，修正后可再次保存。
    private func saveEntityPageViaPipeline(page: WikiPage, markdown: String) {
        setBusy(true, status: "保存中…")
        let payload: [String: Any] = ["original_name": page.name, "markdown": markdown]
        PipelineRunner.shared.run(script: nil, arguments: ["--edit-wiki-page", jsonString(payload)]) { _ in }
        completion: { [weak self] result in
            guard let self else { return }
            // pipeline 的业务错误写在 stdout 的 "ERR …"（退出码 2），stderr 只有 JSON 进度日志，
            // 所以必须从 stdout 取真正原因，否则用户只能看到「异常退出，退出码 2」。
            if let reason = Self.pipelineErrorReason(result.stdout) ?? result.error?.localizedDescription {
                self.setBusy(false, status: "保存失败")
                if reason.contains("Operation not permitted") || reason.contains("permission") {
                    self.presentBaseDirAccessReset(message: "保存失败：\(reason)")
                } else {
                    self.showAlert("保存失败：\(reason)\n\n当前编辑内容仍保留在编辑器中，修正后可再次保存。")
                }
                return
            }
            self.setBusy(false, status: "已保存 · \(page.name)")
            // 成功：stdout 为 "OK <新文件绝对路径>"。改名时文件名会变，用回传文件名回选目标页
            // 并重载正文（让用户看到规范化后的 frontmatter）；未改名则只静默刷新列表
            // （同步别名/共享索引），不动编辑器，避免光标与滚动位置被重置。
            let savedFile = Self.pipelineOKPath(result.stdout).map { ($0 as NSString).lastPathComponent }
            if let f = savedFile, f != page.file {
                self.refreshPagesFromPipeline(silent: false, reselectFile: f)
            } else {
                self.refreshPagesFromPipeline(silent: true)
            }
        }
    }

    /// 从 pipeline stdout 取业务错误原因（约定：末行 `ERR <原因>`）；没有错误则返回 nil。
    static func pipelineErrorReason(_ stdout: String) -> String? {
        for line in stdout.components(separatedBy: .newlines).reversed() {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.hasPrefix("ERR") else { continue }
            let reason = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return reason.isEmpty ? "未知错误" : reason
        }
        return nil
    }

    /// 从 pipeline stdout 取 `OK <路径>` 里的路径部分（`--edit-wiki-page` 回传新页面绝对路径）。
    static func pipelineOKPath(_ stdout: String) -> String? {
        for line in stdout.components(separatedBy: .newlines).reversed() {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.hasPrefix("OK ") else { continue }
            let p = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return p.isEmpty ? nil : p
        }
        return nil
    }

    func markdownEditorDidClickWikilink(_ editor: MarkdownEditorView, name: String, anchor: String?) {
        resolveOrPromptWikiPage(name, anchor: anchor)
    }

    /// v2.2.68：用户在正文末尾「双链关系」表格输入页面名并回车 → 建立双链。
    /// - mode "out"：在当前页正文末尾插入 [[name]]（目标页不存在则先自动新建），即「本页引用该页」。
    /// - mode "in"：在目标页正文追加 [[当前页]]（目标页不存在则先自动新建），即「该页引用本页」。
    /// 两种模式都就地刷新对应表格区（内存更新），无需整页重载，避免丢失编辑器中的未保存改动。
    func markdownEditorDidRequestAddPageLink(_ editor: MarkdownEditorView, mode: String, name: String) {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        guard let current = selectedPage else { return }
        resolveOrCreatePage(named: target) { [weak self] page in
            guard let self, let page = page else { return }
            if mode == "in" {
                // 目标页正文追加 [[当前页]]，使其成为「引用本页的页面」
                self.appendLinkToPageBody(page.file, linkName: current.name, isHome: page.isHome)
                // 立即刷入链表（内存）
                var inc = self.currentIncoming
                if !inc.contains(where: { ($0["name"] as? String)?.lowercased() == page.name.lowercased() }) {
                    var fields: [[String: String]] = []
                    if let tText = try? String(contentsOf: page.isHome ? self.homeFile : self.wikiPagesDir.appendingPathComponent(page.file), encoding: .utf8) {
                        let fm = self.parseFrontmatterScalar(tText)
                        let t = (fm["type"] ?? page.type).lowercased()
                        for w in WikiViewController.referenceWantedKeys(for: t) {
                            if let v = fm[w], !v.isEmpty { fields.append(["label": Self.backlinkFieldLabel(w), "value": v]) }
                        }
                    }
                    var dict: [String: Any] = ["name": page.name, "type": page.type]
                    if !fields.isEmpty { dict["fields"] = fields }
                    inc.append(dict)
                    self.currentIncoming = inc
                    self.editor.setPageReferences(inc)
                }
            } else {
                // out：在当前编辑器正文末尾插入 [[page.name]]（保活，不重载）
                self.editor.appendWikiLink(page.name)
                // 立即刷出链表（内存）
                var out = self.currentOutgoing
                if !out.contains(where: { ($0["name"] as? String)?.lowercased() == page.name.lowercased() }) {
                    var dict: [String: Any] = ["name": page.name, "type": page.type]
                    out.append(dict)
                    self.currentOutgoing = out
                    self.editor.setPageReferencesOut(out)
                }
            }
            // 新建的页已入库：刷新页面名列表（双链自动补全 / 缺失页判定）
            self.editor.setWikiPages(self.pages.flatMap { [$0.name] + $0.aliases })
        }
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
        // v2.2.75【反向互通】没命中 WiKi 页时，先看是不是一份会议纪要 ——
        // 两个库互通，Wiki 页里的 [[纪要名]] 应当能直接跳到纪要页，而不是弹「新建 WiKi 页」。
        if Self.minuteURL(named: name) != nil {
            (self.parent as? MainContainerViewController)?.openMinute(name, anchor: anchor)
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
    /// v2.2.75：把会议纪要名一并纳入 —— WiKi 页正文里的 [[纪要名]] 也应识别为已知页、可跳转。
    func markdownEditorRequestsPageList(_ editor: MarkdownEditorView) -> [String] {
        Array(Set(pages.flatMap { [$0.name] + $0.aliases } + Self.minuteNames()))
    }

    /// v2.2.75：列出 003_Meeting_Minutes 下所有纪要名（去扩展名，含 imported_* 子目录）。
    static func minuteNames() -> [String] {
        let dir = AppConfig.shared.baseDir.appendingPathComponent("003_Meeting_Minutes")
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "md" {
            out.append(url.deletingPathExtension().lastPathComponent)
        }
        return out
    }

    /// 悬浮预览：v2.2.75 起改为「按区块返回」——
    ///   [[页面#区块]] → 只返回该区块（标题 + 其下内容，到下一个同级标题为止）
    ///   [[页面]]      → 只返回「概要块」（H1 之后到首个二级标题之前）
    /// 此前无条件回返全文，导致 frontmatter 的 Company 双链把整页内容都倾泻到气泡里。
    func markdownEditorPreviewForWikilink(_ editor: MarkdownEditorView, name: String) -> String? {
        let (base, anchor) = MinutesViewController.splitTarget(name)
        guard let text = pageMarkdown(forRawName: base) else { return nil }
        if let a = anchor, !a.isEmpty, let block = MarkdownBlocks.block(named: a, in: text) { return block }
        let summary = MarkdownBlocks.summaryBlock(in: text)
        return summary.isEmpty ? nil : summary
    }

    /// v2.2.75：[[页面#区块]] 补全 —— 回返目标页（WiKi 页或纪要）的区块标题列表。
    func markdownEditorHeadings(_ editor: MarkdownEditorView, forPage page: String) -> [String] {
        let (base, _) = MinutesViewController.splitTarget(page)
        guard let text = pageMarkdown(forRawName: base) else { return [] }
        return MarkdownBlocks.headings(in: text)
    }

    /// 读取一页正文（含 frontmatter）：先按 WiKi 页解析，再回退到 003_Meeting_Minutes 的同名纪要。
    /// —— 两个库互通，所以查找顺序上「本模块优先、跨模块兜底」。
    private func pageMarkdown(forRawName raw: String) -> String? {
        if let (_, page) = resolveWikiPage(in: pages, rawName: raw) {
            let url = page.isHome ? homeFile : wikiPagesDir.appendingPathComponent(page.file)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        if let url = Self.minuteURL(named: raw), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return nil
    }

    /// v2.2.75：在 003_Meeting_Minutes（含 imported_* 子目录）里按名称找纪要文件。
    static func minuteURL(named raw: String) -> URL? {
        let name = raw.replacingOccurrences(of: "📥 ", with: "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let dir = AppConfig.shared.baseDir.appendingPathComponent("003_Meeting_Minutes")
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in en {
            guard url.pathExtension.lowercased() == "md" else { continue }
            if url.deletingPathExtension().lastPathComponent == name { return url }
        }
        return nil
    }

    // MARK: - frontmatter 解析/渲染的唯一出口在 pipeline.py
    //
    // v2.2.60 移除：parseWikiPageSpec / parseFrontmatterDict / stripQuoted /
    // composeMarkdown / _blockList / extractBody（六个 Swift 侧 frontmatter 互转函数）。
    // 移除理由（契约审计）：
    //   ① 零调用点 —— 全工程 grep 确认互相调用、无任何外部调用方（App 从未真正用过）；
    //   ② 契约漂移 —— composeMarkdown 写的是小写键（type/canonical_name/tags/updated），
    //      而 v2.2.33 起磁盘契约已是 TitleCase（Type/CanonicalName/Tags/Updated）+ 中文字段，
    //      留着等于埋了一颗「哪天接上就写坏数据」的雷。
    // 现在的分工：读 frontmatter → 编辑器内 JS（MarkdownEditorView 的 renderFrontmatterBanner，
    // 原样 round-trip 保留键名大小写）；写 frontmatter → 只有 pipeline.py render_wiki_page 一个出口。
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
        titleField.alignment = .left   // 左对齐（v2.2.41：回退 v2.2.40 的居中，保留圆角高亮框）
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
