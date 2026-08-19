//
//  SettingsViewController.swift
//  Meetinsight
//
//  设置页（分页 ③）：
//  - whisper.cpp 文件夹选择（自动解析 whisper-cli 二进制；可选下载构建）。
//  - 语音模型档位选择 + 下载（复用向导逻辑，智能扫描本机已有模型）。
//  - 自定义系统提示词（覆盖默认纪要 prompt，写入 MM_LLM_SYSTEM_PROMPT）。
//  - 恢复默认按钮（重置 whisper 路径与自定义提示词）。
//

import Cocoa

final class SettingsViewController: NSViewController, URLSessionDownloadDelegate {

    // MARK: - whisper.cpp 文件夹
    private let whisperPathField = NSTextField(labelWithString: "")
    private let chooseWhisperBtn = NSButton(title: "选择 whisper.cpp 文件夹…", target: nil, action: nil)
    private let buildWhisperBtn = NSButton(title: "下载并构建 whisper.cpp", target: nil, action: nil)

    // MARK: - 模型
    private let MODEL_INFO: [(id: String, label: String, approxMB: Int)] = [
        ("tiny",     "tiny · ~75 MB",      75),
        ("base",     "base · ~142 MB",     142),
        ("small",    "small · ~466 MB",    466),
        ("medium",   "medium · ~1.5 GB",   1500),
        ("large-v3", "large-v3 · ~3.0 GB", 3000),
        ("turbo",    "turbo · ~1.5 GB",    1500)
    ]
    private let MODEL_BASE_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelInfoLabel = NSTextField(labelWithString: "")
    private let scanResultLabel = NSTextField(labelWithString: "")
    private let modelProgressBar = NSProgressIndicator()
    private let modelStatusLabel = NSTextField(labelWithString: "未下载")
    private let modelActionBtn = NSButton(title: "下载所选模型", target: nil, action: nil)
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }()
    private var destination: URL?
    private var existingModels: [String: URL] = [:]

    // MARK: - 语音模型 · 自主定位（v2.2.50）
    private let chooseModelFileBtn = NSButton(title: "选择模型文件…", target: nil, action: nil)

    // MARK: - RAG 嵌入模型（v2.2.50/51 改为下拉菜单）
    private let RAG_MODEL_INFO: [(id: String, label: String, hfId: String, dim: Int, approxMB: Int, desc: String)] = [
        ("small-zh", "BGE-small-zh · 512维 · ~90MB",      "BAAI/bge-small-zh-v1.5", 512,   90, "最轻量，CPU 极快。中文专用，英文实体名检索能力有限。"),
        ("base-zh",  "BGE-base-zh · 768维 · ~400MB",      "BAAI/bge-base-zh-v1.5",  768,  400, "中文质量提升，体积适中。仍以中文为主，英文能力有改善。"),
        ("large-zh", "BGE-large-zh · 1024维 · ~1.3GB",    "BAAI/bge-large-zh-v1.5", 1024, 1300, "BGE 中文系列最强。英文能力优于 small/base，但仍弱于 M3。"),
        ("m3",       "BGE-M3 · 1024维 · ~2.3GB（推荐）",   "BAAI/bge-m3",            1024, 2300, "中英双语最强。100+ 语种、8192 token 长文档、三模融合检索。无需前缀。"),
    ]
    private let ragModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ragModelDescLabel = NSTextField(labelWithString: "")
    private let ragModelPathField = NSTextField(labelWithString: "")
    private let chooseRAGModelBtn = NSButton(title: "浏览本机嵌入模型…", target: nil, action: nil)
    private let downloadRAGModelBtn = NSButton(title: "下载所选模型", target: nil, action: nil)
    private let ragStatusLabel = NSTextField(labelWithString: "")
    private var ragDownloadProcess: Process?

    // MARK: - 自定义提示词
    private let promptView = NSTextView()
    private let savePromptBtn = NSButton(title: "保存提示词", target: nil, action: nil)

    // MARK: - 工作目录（v2.2.13：重设授权兜底）
    private let baseDirField = NSTextField(labelWithString: "")
    private let resetBaseDirBtn = NSButton(title: "重设工作目录…", target: nil, action: nil)
    private let baseDirHint = NSTextField(labelWithString:
        "App 重启后若 WiKi / 纪要报「Operation not permitted」，点此重新选择同一目录即可恢复授权（无需重装）。")

    // MARK: - 恢复默认
    private let restoreBtn = NSButton(title: "恢复默认", target: nil, action: nil)

    override func loadView() { view = NSView(); view.wantsLayer = true }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refreshBaseDir()
        refreshWhisperPath()
        refreshPrompt()
        existingModels = scanExistingModels()
        renderScanResult()
        applySmartSelection()
        refreshModelActionButton()
        applyRAGSmartSelection()
        refreshRAGModelPath()
    }

    // MARK: - 工作目录（v2.2.13）

    private func refreshBaseDir() {
        baseDirField.stringValue = AppConfig.shared.baseDir.path
    }

    @objc private func resetBaseDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "重新选择工作目录（建议选回原来的目录）"
        panel.prompt = "设为工作目录"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            // 写路径 + 持久化 security-scoped bookmark，并立即恢复授权。
            AppConfig.shared.setBaseDir(url)
            _ = AppConfig.shared.startAccessingBaseDir()
            self?.refreshBaseDir()
            AppAlert.show(
                message: "已重设工作目录",
                informative: "工作目录已更新为：\n\(url.path)\n\n对该目录的访问授权已恢复，可重新打开 LLM WiKi 验证。",
                icon: .save
            )
        }
    }

    // MARK: - UI

    private func setupUI() {
        let pad: CGFloat = 16
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        // —— 工作目录（v2.2.13 置顶）——
        stack.addArrangedSubview(sectionTitle("工作目录（MM_BASE_DIR）"))
        baseDirField.lineBreakMode = .byTruncatingMiddle
        baseDirField.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(makeLabel("当前工作目录：", bold: true))
        stack.addArrangedSubview(baseDirField)
        resetBaseDirBtn.bezelStyle = .rounded
        resetBaseDirBtn.target = self; resetBaseDirBtn.action = #selector(resetBaseDir)
        stack.addArrangedSubview(resetBaseDirBtn)
        baseDirHint.font = NSFont.systemFont(ofSize: 11)
        baseDirHint.textColor = .secondaryLabelColor
        baseDirHint.lineBreakMode = .byWordWrapping
        baseDirHint.maximumNumberOfLines = 0
        baseDirHint.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(baseDirHint)

        stack.addArrangedSubview(divider())

        // —— whisper.cpp 文件夹 ——
        stack.addArrangedSubview(sectionTitle("语音转写引擎 · whisper.cpp"))
        stack.addArrangedSubview(makeLabel("whisper-cli 路径：", bold: true))
        whisperPathField.lineBreakMode = .byTruncatingMiddle
        whisperPathField.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(whisperPathField)
        chooseWhisperBtn.bezelStyle = .rounded
        chooseWhisperBtn.target = self; chooseWhisperBtn.action = #selector(chooseWhisperFolder)
        buildWhisperBtn.bezelStyle = .rounded
        buildWhisperBtn.target = self; buildWhisperBtn.action = #selector(buildWhisper)
        let whisperRow = NSStackView(views: [chooseWhisperBtn, buildWhisperBtn])
        whisperRow.spacing = 10
        stack.addArrangedSubview(whisperRow)

        stack.addArrangedSubview(divider())

        // —— 模型 ——
        stack.addArrangedSubview(sectionTitle("语音模型"))
        stack.addArrangedSubview(makeLabel("模型文件只保存在本机，不会上传。已下载过的会自动识别。", size: 12))
        MODEL_INFO.forEach { modelPopup.addItem(withTitle: $0.label) }
        modelPopup.target = self; modelPopup.action = #selector(modelSelected)
        stack.addArrangedSubview(formRow("模型档位", modelPopup))
        stack.addArrangedSubview(modelInfoLabel)
        stack.addArrangedSubview(scanResultLabel)
        modelProgressBar.style = .bar
        modelProgressBar.minValue = 0; modelProgressBar.maxValue = 100
        modelProgressBar.doubleValue = 0; modelProgressBar.isIndeterminate = false
        modelProgressBar.translatesAutoresizingMaskIntoConstraints = false
        modelProgressBar.widthAnchor.constraint(equalToConstant: 480).isActive = true
        stack.addArrangedSubview(modelProgressBar)
        stack.addArrangedSubview(modelStatusLabel)
        modelActionBtn.bezelStyle = .rounded
        modelActionBtn.target = self; modelActionBtn.action = #selector(modelActionClicked)
        // v2.2.50: 自主定位模型文件（与 whisper.cpp 的「选择文件夹」一致）
        chooseModelFileBtn.bezelStyle = .rounded
        chooseModelFileBtn.target = self; chooseModelFileBtn.action = #selector(chooseModelFile)
        let modelActionRow = NSStackView(views: [modelActionBtn, chooseModelFileBtn])
        modelActionRow.spacing = 10
        stack.addArrangedSubview(modelActionRow)

        stack.addArrangedSubview(divider())

        // —— RAG 嵌入模型（v2.2.50/51，下拉菜单选择 BGE 规格）——
        stack.addArrangedSubview(sectionTitle("RAG 嵌入模型"))
        stack.addArrangedSubview(makeLabel("嵌入模型用于本地语义检索（WiKi 知识库向量化），不会上传。已下载的会自动识别。", size: 12))
        RAG_MODEL_INFO.forEach { ragModelPopup.addItem(withTitle: $0.label) }
        ragModelPopup.target = self; ragModelPopup.action = #selector(ragModelSelected)
        stack.addArrangedSubview(formRow("模型档位", ragModelPopup))
        ragModelDescLabel.font = NSFont.systemFont(ofSize: 12)
        ragModelDescLabel.lineBreakMode = .byWordWrapping
        ragModelDescLabel.maximumNumberOfLines = 0
        ragModelDescLabel.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(ragModelDescLabel)
        stack.addArrangedSubview(makeLabel("嵌入模型路径：", bold: true))
        ragModelPathField.lineBreakMode = .byTruncatingMiddle
        ragModelPathField.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(ragModelPathField)
        chooseRAGModelBtn.bezelStyle = .rounded
        chooseRAGModelBtn.target = self; chooseRAGModelBtn.action = #selector(chooseRAGModelFolder)
        downloadRAGModelBtn.bezelStyle = .rounded
        downloadRAGModelBtn.target = self; downloadRAGModelBtn.action = #selector(downloadRAGModel)
        let ragRow = NSStackView(views: [chooseRAGModelBtn, downloadRAGModelBtn])
        ragRow.spacing = 10
        stack.addArrangedSubview(ragRow)
        ragStatusLabel.font = NSFont.systemFont(ofSize: 12)
        ragStatusLabel.lineBreakMode = .byWordWrapping
        ragStatusLabel.maximumNumberOfLines = 0
        ragStatusLabel.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(ragStatusLabel)

        stack.addArrangedSubview(divider())

        // —— 自定义提示词 ——
        stack.addArrangedSubview(sectionTitle("自定义系统提示词"))
        stack.addArrangedSubview(makeLabel("留空则使用内置默认提示词（半导体/硬件供应链纪要专家）。填写后整体替换生成纪要的 system prompt。", size: 12))
        promptView.isEditable = true; promptView.isSelectable = true
        promptView.font = .systemFont(ofSize: 12)
        promptView.backgroundColor = .textBackgroundColor
        let promptScroll = NSScrollView()
        promptScroll.hasVerticalScroller = true
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.documentView = promptView
        promptScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        promptScroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        stack.addArrangedSubview(promptScroll)
        savePromptBtn.bezelStyle = .rounded
        savePromptBtn.target = self; savePromptBtn.action = #selector(savePrompt)
        stack.addArrangedSubview(savePromptBtn)

        stack.addArrangedSubview(divider())

        // —— 恢复默认 ——
        restoreBtn.bezelStyle = .rounded
        restoreBtn.target = self; restoreBtn.action = #selector(restoreDefaults)
        stack.addArrangedSubview(restoreBtn)

        // 外层滚动容器
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        view.addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: pad),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad),
            // documentView 跟随可见宽度（无水平滚动），高度由内容决定 → 纵向滚动
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
    }

    // MARK: - whisper.cpp

    private func refreshWhisperPath() {
        whisperPathField.stringValue = AppConfig.shared.whisperCLI.path
    }

    @objc private func chooseWhisperFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            guard let cli = self?.resolveWhisperCLI(in: url) else {
                self?.presentError("在该文件夹内未找到 whisper-cli（通常位于 build/bin/whisper-cli）。请选择 whisper.cpp 仓库根目录，或点「下载并构建」。")
                return
            }
            AppConfig.shared.whisperCLI = cli
            self?.refreshWhisperPath()
        }
    }

    /// 在给定文件夹内解析 whisper-cli：优先 <folder>/build/bin/whisper-cli，其次 <folder>/whisper-cli。
    private func resolveWhisperCLI(in folder: URL) -> URL? {
        let candidates = [
            folder.appendingPathComponent("build/bin/whisper-cli"),
            folder.appendingPathComponent("whisper-cli")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @objc private func buildWhisper() {
        let dest = URL(fileURLWithPath: "/Users/weilu/whisper.cpp")
        let script = """
        set -e
        rm -rf '\(dest.path)'
        git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git '\(dest.path)'
        cd '\(dest.path)'
        cmake -B build -DWHISPER_BUILD_CLI=ON
        cmake --build build -j
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let data = h.availableData.nonEmpty, let s = String(data: data, encoding: .utf8) else { return }
            print("[buildWhisper] \(s.trimmingCharacters(in: .newlines))")
            _ = self
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    let cli = dest.appendingPathComponent("build/bin/whisper-cli")
                    if FileManager.default.fileExists(atPath: cli.path) {
                        AppConfig.shared.whisperCLI = cli
                        self?.refreshWhisperPath()
                    }
                }
            }
        }
        try? proc.run()
    }

    // MARK: - 模型扫描 / 选择 / 下载

    private func scanExistingModels() -> [String: URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        if FileManager.default.fileExists(atPath: AppConfig.shared.whisperModel.path) {
            dirs.append(AppConfig.shared.whisperModel.deletingLastPathComponent())
        }
        let cli = AppConfig.shared.whisperCLI
        if fm.fileExists(atPath: cli.path) {
            let root = cli.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            dirs.append(root.appendingPathComponent("models"))
        }
        dirs.append(URL(fileURLWithPath: "/Users/weilu/whisper.cpp/models"))

        var found: [String: URL] = [:]
        for dir in dirs where fm.fileExists(atPath: dir.path) {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files where file.pathExtension == "bin" && file.lastPathComponent.hasPrefix("ggml-") {
                let id = String(file.lastPathComponent.dropFirst("ggml-".count).dropLast(".bin".count))
                if found[id] == nil { found[id] = file }
            }
        }
        return found
    }

    private func renderScanResult() {
        if existingModels.isEmpty {
            scanResultLabel.stringValue = "🔍 未在本机发现任何 ggml 模型。请选择一个档位并下载。"
            scanResultLabel.textColor = .secondaryLabelColor
        } else {
            let lines = existingModels.keys.sorted().map { id in
                "  • ggml-\(id).bin  (\(humanSize(fileSize(at: URL(fileURLWithPath: existingModels[id]!.path))))"
            }
            scanResultLabel.stringValue = "✅ 已在本机发现以下模型（点「使用此模型」即可，无需下载）：\n" + lines.joined(separator: "\n")
            scanResultLabel.textColor = .systemGreen
        }
    }

    private func applySmartSelection() {
        let configured = AppConfig.shared.whisperModel
        if FileManager.default.fileExists(atPath: configured.path),
           configured.lastPathComponent.hasPrefix("ggml-"), configured.lastPathComponent.hasSuffix(".bin") {
            let id = String(configured.lastPathComponent.dropFirst("ggml-".count).dropLast(".bin".count))
            if let idx = MODEL_INFO.firstIndex(where: { $0.id == id }) { modelPopup.selectItem(at: idx); updateModelInfo(); return }
        }
        if let firstId = existingModels.keys.sorted().first,
           let idx = MODEL_INFO.firstIndex(where: { $0.id == firstId }) { modelPopup.selectItem(at: idx) }
        else if let idx = MODEL_INFO.firstIndex(where: { $0.id == "large-v3" }) { modelPopup.selectItem(at: idx) }
        updateModelInfo()
    }

    private func updateModelInfo() {
        guard let item = MODEL_INFO[safe: modelPopup.indexOfSelectedItem] else { return }
        modelInfoLabel.stringValue = "文件名：ggml-\(item.id).bin · 约 \(item.approxMB) MB"
    }

    private func refreshModelActionButton() {
        guard let item = MODEL_INFO[safe: modelPopup.indexOfSelectedItem] else { return }
        if let existing = existingModels[item.id] {
            modelActionBtn.title = "使用此模型"
            modelStatusLabel.stringValue = "✅ 已就绪 · ggml-\(item.id).bin (\(humanSize(fileSize(at: existing))))"
        } else {
            modelActionBtn.title = "下载所选模型"
            modelStatusLabel.stringValue = "未下载 · ggml-\(item.id).bin"
        }
        modelProgressBar.doubleValue = 0
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    private func humanSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    @objc private func modelSelected() { updateModelInfo(); refreshModelActionButton() }

    @objc private func modelActionClicked() {
        guard let item = MODEL_INFO[safe: modelPopup.indexOfSelectedItem] else { return }
        if let existing = existingModels[item.id] { useExistingModel(existing) }
        else { startDownload() }
    }

    private func useExistingModel(_ url: URL) {
        AppConfig.shared.whisperModel = url
        modelStatusLabel.stringValue = "✅ 已采用：\(url.lastPathComponent) (\(humanSize(fileSize(at: url))))"
        modelProgressBar.doubleValue = 100
    }

    @objc private func startDownload() {
        guard let item = MODEL_INFO[safe: modelPopup.indexOfSelectedItem] else { return }
        let modelsDir = AppConfig.shared.whisperCLI
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let dest = modelsDir.appendingPathComponent("ggml-\(item.id).bin")
        destination = dest
        AppConfig.shared.whisperModel = dest
        let url = URL(string: MODEL_BASE_URL + "ggml-\(item.id).bin")!
        modelStatusLabel.stringValue = "准备下载…"
        modelActionBtn.isEnabled = false
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        modelProgressBar.doubleValue = frac * 100
        modelStatusLabel.stringValue = String(format: "下载中… %.0f%%", frac * 100)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destination else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            if let item = MODEL_INFO[safe: modelPopup.indexOfSelectedItem] {
                existingModels[item.id] = dest
                renderScanResult(); refreshModelActionButton()
            }
        } catch { modelStatusLabel.stringValue = "❌ 保存失败：\(error.localizedDescription)" }
        modelActionBtn.isEnabled = true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { modelStatusLabel.stringValue = "❌ 下载失败：\(error.localizedDescription)" }
        modelActionBtn.isEnabled = true
    }

    // MARK: - 语音模型 · 自主定位（v2.2.50）

    @objc private func chooseModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 whisper.cpp 的 ggml 模型文件（ggml-*.bin）"
        panel.prompt = "采用此模型"
        panel.directoryURL = AppConfig.shared.whisperModel.deletingLastPathComponent()
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            guard url.pathExtension == "bin" else {
                self?.presentError("请选择 .bin 格式的 ggml 模型文件。")
                return
            }
            AppConfig.shared.whisperModel = url
            // 刷新扫描结果与按钮状态
            self?.existingModels = self?.scanExistingModels() ?? [:]
            self?.renderScanResult()
            self?.applySmartSelection()
            self?.refreshModelActionButton()
            self?.modelStatusLabel.stringValue = "✅ 已采用：\(url.lastPathComponent)"
            self?.modelProgressBar.doubleValue = 100
        }
    }

    // MARK: - RAG 嵌入模型（v2.2.50/51，下拉菜单选择 BGE 规格）

    private let RAG_MIRROR = "https://hf-mirror.com"

    private var ragDownloadDir: URL {
        let m = RAG_MODEL_INFO[safe: ragModelPopup.indexOfSelectedItem] ?? RAG_MODEL_INFO[0]
        let dirName = m.hfId.split(separator: "/").last.map(String.init) ?? "bge-small-zh-v1.5"
        return AppConfig.shared.huggingfaceHome.appendingPathComponent(dirName)
    }

    private func currentRAGModel() -> (id: String, label: String, hfId: String, dim: Int, approxMB: Int, desc: String) {
        RAG_MODEL_INFO[safe: ragModelPopup.indexOfSelectedItem] ?? RAG_MODEL_INFO[0]
    }

    private func applyRAGSmartSelection() {
        let key = AppConfig.shared.ragModelKey
        if let idx = RAG_MODEL_INFO.firstIndex(where: { $0.id == key }) {
            ragModelPopup.selectItem(at: idx)
        } else {
            ragModelPopup.selectItem(at: 0)
        }
        updateRAGModelDesc()
    }

    private func updateRAGModelDesc() {
        let m = currentRAGModel()
        let sizeStr = m.approxMB >= 1024
            ? String(format: "%.1f GB", Double(m.approxMB) / 1024)
            : "\(m.approxMB) MB"
        ragModelDescLabel.stringValue = "\(m.desc)（\(m.dim) 维，约 \(sizeStr)）"
    }

    @objc private func ragModelSelected() {
        let m = currentRAGModel()
        AppConfig.shared.ragModelKey = m.id
        updateRAGModelDesc()
        refreshRAGModelPath()
    }

    private func refreshRAGModelPath() {
        let m = currentRAGModel()
        let modelName = m.hfId.split(separator: "/").last.map(String.init) ?? m.id
        if AppConfig.shared.embeddingModelSkipped {
            ragModelPathField.stringValue = "（已跳过 RAG）"
            ragStatusLabel.stringValue = "⏭️ RAG 语义检索已停用，WiKi 检索降级为关键词匹配。点「浏览」或「下载」可重新启用。"
            ragStatusLabel.textColor = .systemOrange
        } else if let p = AppConfig.shared.embeddingModelPath,
                  FileManager.default.fileExists(atPath: p.path) {
            ragModelPathField.stringValue = p.path
            ragStatusLabel.stringValue = "✅ 已就绪：\(p.lastPathComponent)"
            ragStatusLabel.textColor = .systemGreen
        } else {
            let dl = ragDownloadDir
            let hasWeights = FileManager.default.fileExists(atPath: dl.appendingPathComponent("model.safetensors").path)
                         || FileManager.default.fileExists(atPath: dl.appendingPathComponent("pytorch_model.bin").path)
            if hasWeights {
                AppConfig.shared.embeddingModelPath = dl
                ragModelPathField.stringValue = dl.path
                ragStatusLabel.stringValue = "✅ 已就绪：\(modelName)（位于沙箱缓存）"
                ragStatusLabel.textColor = .systemGreen
            } else {
                ragModelPathField.stringValue = "（未配置）"
                let sizeStr = m.approxMB >= 1024
                    ? String(format: "%.1f GB", Double(m.approxMB) / 1024)
                    : "\(m.approxMB) MB"
                ragStatusLabel.stringValue = "🔍 未检测到 \(modelName) 模型。点「下载所选模型」自动下载（约 \(sizeStr)，国内镜像），或「浏览本机嵌入模型…」指定本机已有目录。"
                ragStatusLabel.textColor = .secondaryLabelColor
            }
        }
    }

    @objc private func chooseRAGModelFolder() {
        let m = currentRAGModel()
        let modelName = m.hfId.split(separator: "/").last.map(String.init) ?? m.id
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = AppConfig.shared.embeddingModelPath ?? ragDownloadDir
        panel.message = "选择含 \(modelName) 模型文件的目录（需包含 config.json + model.safetensors 或 pytorch_model.bin）"
        panel.prompt = "采用此目录"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            guard Self.isValidEmbeddingDir(url) else {
                self?.presentError("所选目录不是有效的嵌入模型目录（需要 config.json + model.safetensors/pytorch_model.bin）。")
                return
            }
            AppConfig.shared.embeddingModelPath = url
            AppConfig.shared.embeddingModelSkipped = false
            self?.refreshRAGModelPath()
        }
    }

    private static func isValidEmbeddingDir(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
        let weights = ["model.safetensors", "pytorch_model.bin",
                       "pytorch_model.bin.index.json", "model.safetensors.index.json"]
        return weights.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    @objc private func downloadRAGModel() {
        let m = currentRAGModel()
        let modelName = m.hfId.split(separator: "/").last.map(String.init) ?? m.id
        AppConfig.shared.embeddingUseMirror = true
        AppConfig.shared.embeddingModelPath = nil
        AppConfig.shared.embeddingModelSkipped = false
        let py = AppConfig.shared.pythonExecutable.path
        let localDir = ragDownloadDir.path
        let sizeStr = m.approxMB >= 1024
            ? String(format: "%.1f GB", Double(m.approxMB) / 1024)
            : "\(m.approxMB) MB"
        ragStatusLabel.stringValue = "下载中… \(modelName)（约 \(sizeStr)，国内镜像 hf-mirror.com）"
        ragStatusLabel.textColor = .systemBlue
        downloadRAGModelBtn.isEnabled = false

        let pyScript = """
        from huggingface_hub import snapshot_download
        p = snapshot_download("\(m.hfId)", local_dir='\(localDir)', local_dir_use_symlinks=False)
        print("LOCAL_DIR=" + p)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = AppConfig.shared.huggingfaceHome.path
        env["HF_ENDPOINT"] = RAG_MIRROR
        proc.environment = env
        proc.arguments = ["-c", "\(shellQuote(py)) -c \(shellQuote(pyScript))"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            guard let data = h.availableData.nonEmpty, let s = String(data: data, encoding: .utf8) else { return }
            print("[RAG download] \(s.trimmingCharacters(in: .newlines))")
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.downloadRAGModelBtn.isEnabled = true
                if p.terminationStatus == 0 {
                    AppConfig.shared.embeddingModelPath = self?.ragDownloadDir
                    self?.refreshRAGModelPath()
                } else {
                    self?.ragStatusLabel.stringValue = "❌ 下载失败（退出码 \(p.terminationStatus)）。请检查网络，或点「浏览本机嵌入模型…」指定本机已有目录。"
                    self?.ragStatusLabel.textColor = .systemRed
                }
            }
        }
        ragDownloadProcess = proc
        try? proc.run()
    }

    // MARK: - 自定义提示词

    private func refreshPrompt() {
        // 若已保存过用户自定义，则显示它；
        // 否则预填 pipeline.py 的默认 system prompt,让用户可以直接基于此修改。
        if let saved = AppConfig.shared.customSystemPrompt, !saved.isEmpty {
            promptView.string = saved
        } else {
            promptView.string = AppConfig.shared.defaultSystemPrompt
        }
    }

    @objc private func savePrompt() {
        let text = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        AppConfig.shared.customSystemPrompt = text.isEmpty ? nil : text
        AppAlert.show(
            message: "已保存",
            informative: text.isEmpty ? "已清空自定义提示词，将使用内置默认提示词。" : "自定义系统提示词已保存，下次生成纪要生效。",
            icon: .save
        )
    }

    // MARK: - 恢复默认

    @objc private func restoreDefaults() {
        let resp = AppAlert.show(
            message: "恢复默认设置",
            informative: "将重置：whisper-cli 路径、语音模型、RAG 嵌入模型（档位选择）、自定义提示词。\n（大模型 API Key / 供应商不受影响。）",
            icon: .warning,
            style: .warning,
            buttons: ["恢复", "取消"]
        )
        guard resp == .alertFirstButtonReturn else { return }

        AppConfig.shared.whisperCLI = URL(fileURLWithPath: "/Users/weilu/whisper.cpp/build/bin/whisper-cli")
        AppConfig.shared.whisperModel = URL(fileURLWithPath: "/Users/weilu/whisper.cpp/models/ggml-large-v3.bin")
        AppConfig.shared.customSystemPrompt = nil
        // v2.2.50/51: 重置 RAG 嵌入模型
        AppConfig.shared.embeddingModelSkipped = false
        AppConfig.shared.embeddingModelPath = nil
        AppConfig.shared.embeddingUseMirror = false
        AppConfig.shared.ragModelKey = "small-zh"

        refreshWhisperPath()
        refreshPrompt()
        existingModels = scanExistingModels()
        renderScanResult()
        applySmartSelection()
        refreshModelActionButton()
        applyRAGSmartSelection()
        refreshRAGModelPath()
    }

    // MARK: - 小工具

    private func presentError(_ msg: String) {
        AppAlert.show(message: "无法继续", informative: msg, icon: .error)
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.boldSystemFont(ofSize: 14)
        return f
    }
    private func makeLabel(_ text: String, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        f.lineBreakMode = .byWordWrapping
        f.preferredMaxLayoutWidth = 560
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }
    private func formRow(_ label: String, _ control: NSView) -> NSStackView {
        let h = NSStackView(); h.orientation = .horizontal; h.spacing = 10; h.alignment = .firstBaseline
        let lab = makeLabel(label); lab.setContentCompressionResistancePriority(.required, for: .horizontal)
        lab.widthAnchor.constraint(equalToConstant: 90).isActive = true
        h.addArrangedSubview(lab); h.addArrangedSubview(control)
        return h
    }
    private func divider() -> NSBox {
        let b = NSBox(); b.boxType = .separator; return b
    }
}

/// v2.2.50: shell 引号转义（供 RAG 模型下载脚本用）
fileprivate func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

fileprivate extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
fileprivate extension Data {
    var nonEmpty: Data? { isEmpty ? nil : self }
}
