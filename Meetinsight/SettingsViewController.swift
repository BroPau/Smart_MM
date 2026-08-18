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
        stack.addArrangedSubview(modelActionBtn)

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
            informative: "将重置：whisper-cli 路径、语音模型、自定义提示词。\n（大模型 API Key / 供应商不受影响。）",
            icon: .warning,
            style: .warning,
            buttons: ["恢复", "取消"]
        )
        guard resp == .alertFirstButtonReturn else { return }

        AppConfig.shared.whisperCLI = URL(fileURLWithPath: "/Users/weilu/whisper.cpp/build/bin/whisper-cli")
        AppConfig.shared.whisperModel = URL(fileURLWithPath: "/Users/weilu/whisper.cpp/models/ggml-large-v3.bin")
        AppConfig.shared.customSystemPrompt = nil

        refreshWhisperPath()
        refreshPrompt()
        existingModels = scanExistingModels()
        renderScanResult()
        applySmartSelection()
        refreshModelActionButton()
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

fileprivate extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
fileprivate extension Data {
    var nonEmpty: Data? { isEmpty ? nil : self }
}
