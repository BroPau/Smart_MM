//
//  SetupWizardStepView.swift
//  Meetinsight
//
//  安装向导的六步视图（对应 Swift_Python_Interface_Contract.md §7）：
//   Step1RuntimeView        —— whisper.cpp 二进制定位 / 下载构建
//   Step2ModelView          —— whisper 模型下载（6 档，带进度，可浏览本机已有 .bin）
//   StepPythonEngineView    —— Python 3.11+ 定位 + 依赖安装（numpy/pypinyin/sentence-transformers/google-genai/openai）
//   StepEmbeddingModelView  —— bge-small-zh-v1.5 嵌入模型：下载（本地 RAG）或跳过
//   Step3DirectoryView      —— 工作目录选择（MM_BASE_DIR，创建标准子目录）
//   Step4LLMView            —— 大模型供应商 + API Key（Keychain）
//
//  基类 WizardStepView 负责嵌入容器、标题、校验钩子。每个子类在 buildUI() 中拼接控件。
//

import Cocoa

// MARK: - 基类

class WizardStepView: NSView {

    /// 步骤标题（向导头部大标题）
    var title: String { "" }
    /// 步骤副标题（步骤指示文字）
    var subtitle: String { "" }

    /// 点击「下一步 / 完成」前的校验；返回 false 时阻止前进。
    var validate: (() -> Bool)?
    /// 校验失败时给用户的提示（如高亮 / 弹窗）。
    var showValidationError: (() -> Void)?

    let contentStack: NSStackView = {
        let s = NSStackView()
        s.orientation = .vertical
        s.spacing = 14
        s.alignment = .leading
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    /// 嵌入到向导容器（自动加边距）。
    func embed(in parent: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.topAnchor, constant: 16),
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 16),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -16)
        ])
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        buildUI()
    }

    /// 子类在此构建 UI（已确保 contentStack 存在）。
    func buildUI() {}
}

// MARK: - 通用构造助手

fileprivate func makeLabel(_ text: String, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    f.lineBreakMode = .byWordWrapping
    f.preferredMaxLayoutWidth = 540
    f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return f
}

fileprivate func makeButton(_ title: String, target: Any?, action: Selector?) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    return b
}

/// 一行表单：[固定宽度标签] + [控件]
fileprivate func formRow(_ label: String, _ control: NSView) -> NSStackView {
    let h = NSStackView()
    h.orientation = .horizontal
    h.spacing = 10
    h.alignment = .firstBaseline
    let lab = makeLabel(label)
    lab.setContentCompressionResistancePriority(.required, for: .horizontal)
    lab.widthAnchor.constraint(equalToConstant: 110).isActive = true
    h.addArrangedSubview(lab)
    h.addArrangedSubview(control)
    return h
}

/// 同步运行一个子进程并合并 stdout+stderr 输出。用于向导内的快速检测（如 python --version / import 检查）。
/// 注意：会阻塞调用线程，仅适合在后台线程（DispatchQueue.global）中调用耗时很短的命令。
fileprivate func runProcess(_ executable: String, _ args: [String]) -> (exitCode: Int32, output: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        return (-1, "启动失败: \(error.localizedDescription)")
    }
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    let str = (String(data: o, encoding: .utf8) ?? "") + (String(data: e, encoding: .utf8) ?? "")
    return (proc.terminationStatus, str.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Step 1：whisper.cpp 二进制

final class Step1RuntimeView: WizardStepView {

    override var title: String { "运行环境 · whisper.cpp" }
    override var subtitle: String { "定位或下载构建 whisper.cpp 命令行引擎（C++，不依赖 torch）" }

    private let pathField = NSTextField(labelWithString: "")
    private let logView = NSTextView()
    private let scroll = NSScrollView()
    private var buildProcess: Process?

    override func buildUI() {
        contentStack.addArrangedSubview(makeLabel(
            "Meetinsight 使用 whisper.cpp（C++）做语音转写，性能远优于纯 Python 方案，且无需庞大的 torch 依赖。", size: 12))
        contentStack.addArrangedSubview(makeLabel("whisper-cli 路径：", bold: true))

        pathField.stringValue = AppConfig.shared.whisperCLI.path
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.preferredMaxLayoutWidth = 480
        contentStack.addArrangedSubview(pathField)

        let browse = makeButton("浏览已有二进制…", target: self, action: #selector(browseBinary))
        let build = makeButton("下载并构建 whisper.cpp", target: self, action: #selector(downloadAndBuild))
        let h = NSStackView(views: [browse, build])
        h.spacing = 10
        contentStack.addArrangedSubview(h)

        // 构建日志
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = NSColor.textBackgroundColor
        scroll.documentView = logView
        // 先把 scroll 加入容器，再建立跨视图约束——否则 Auto Layout 找不到共同祖先。
        contentStack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 150)
        ])

        validate = { [weak self] in self?.AppConfig_shared.isWhisperCLIPresent ?? false }
        showValidationError = { [weak self] in
            self?.presentError("尚未找到可用的 whisper-cli。请「浏览」指定，或点击「下载并构建」。")
        }
    }

    // 便捷别名，避免可选链在闭包中过长的写法
    private var AppConfig_shared: AppConfig { AppConfig.shared }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            self.logView.string += text + "\n"
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func browseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            AppConfig.shared.whisperCLI = url
            self?.pathField.stringValue = url.path
        }
    }

    @objc private func downloadAndBuild() {
        let dest = URL(fileURLWithPath: "/Users/weilu/whisper.cpp")
        appendLog("将克隆并构建到：\(dest.path)")
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
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let data = h.availableData.nonEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(s.trimmingCharacters(in: .newlines))
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    let cli = dest.appendingPathComponent("build/bin/whisper-cli")
                    if FileManager.default.fileExists(atPath: cli.path) {
                        AppConfig.shared.whisperCLI = cli
                        self?.pathField.stringValue = cli.path
                        self?.appendLog("✅ 构建完成，whisper-cli 已就绪。")
                    } else {
                        self?.appendLog("⚠️ 构建结束但未在预期路径找到 whisper-cli。")
                    }
                } else {
                    self?.appendLog("❌ 构建失败，退出码 \(p.terminationStatus)。请检查网络与 Xcode 命令行工具（xcode-select --install）。")
                }
            }
        }
        buildProcess = proc
        try? proc.run()
    }

    private func presentError(_ msg: String) {
        AppAlert.show(message: "无法继续", informative: msg, icon: .error)
    }
}

// MARK: - Step 2：whisper 模型下载（智能扫描）

final class Step2ModelView: WizardStepView, URLSessionDownloadDelegate {

    override var title: String { "语音模型" }
    override var subtitle: String { "下载 whisper.cpp 的 ggml 模型文件（向导会自动扫描已存在的；若未扫到，也可点「浏览本机模型文件…」手动指定已有 .bin，避免重复下载）" }

    // 与契约 §8 一致
    private let MODEL_INFO: [(id: String, label: String, approxMB: Int)] = [
        ("tiny",     "tiny · ~75 MB",      75),
        ("base",     "base · ~142 MB",     142),
        ("small",    "small · ~466 MB",    466),
        ("medium",   "medium · ~1.5 GB",   1500),
        ("large-v3", "large-v3 · ~3.0 GB", 3000),
        ("turbo",    "turbo · ~1.5 GB",    1500)
    ]
    private let MODEL_BASE_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let infoLabel = NSTextField(labelWithString: "")
    private let scanResultLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "未下载")
    private let actionBtn = NSButton(title: "下载所选模型", target: nil, action: nil)

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }()
    private var destination: URL?
    /// buildUI() 阶段扫描到的本机已有模型（id → URL）。切换档位与下载完成时刷新。
    private var existingModels: [String: URL] = [:]

    override func buildUI() {
        contentStack.addArrangedSubview(makeLabel(
            "模型文件只保存在本机，不会上传。向导会先扫描几个默认位置，已经下载过的不会再让你下载。", size: 12))

        MODEL_INFO.forEach { popup.addItem(withTitle: $0.label) }
        popup.target = self
        popup.action = #selector(modelSelected)

        // --- 智能扫描 + 默认选中 ---
        existingModels = scanExistingModels()
        renderScanResult()
        applySmartSelection()
        contentStack.addArrangedSubview(formRow("模型档位", popup))
        contentStack.addArrangedSubview(infoLabel)
        contentStack.addArrangedSubview(scanResultLabel)

        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.isIndeterminate = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(progressBar)
        progressBar.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.addArrangedSubview(statusLabel)

        actionBtn.bezelStyle = .rounded
        actionBtn.target = self
        actionBtn.action = #selector(actionButtonClicked)

        let browseBtn = makeButton("浏览本机模型文件…", target: self, action: #selector(browseModel))
        let h = NSStackView(views: [browseBtn, actionBtn])
        h.spacing = 10
        contentStack.addArrangedSubview(h)

        refreshActionButton()

        validate = { [weak self] in self?.AppConfig_shared.isWhisperModelPresent ?? false }
        showValidationError = { [weak self] in
            self?.presentError("请先下载模型，或点击「浏览本机模型文件…」手动指定本机已有的 ggml-*.bin 文件。")
        }
    }

    private var AppConfig_shared: AppConfig { AppConfig.shared }

    // MARK: - 扫描 + 智能选中

    /// 扫描若干默认位置，返回 id → 本地 .bin URL 的映射。
    /// 顺序：① AppConfig 已存模型的父目录 ② whisperCLI 推导的 models/ ③ 默认 whisper.cpp/models/
    ///       ④ ~/Downloads ⑤ ~/Desktop ⑥ ~/Documents（常见手动下载落点）
    /// 同一 id 多处出现时，取先扫到的。
    private func scanExistingModels() -> [String: URL] {
        let fm = FileManager.default
        var dirs: [URL] = []

        if FileManager.default.fileExists(atPath: AppConfig.shared.whisperModel.path) {
            dirs.append(AppConfig.shared.whisperModel.deletingLastPathComponent())
        }
        let cli = AppConfig.shared.whisperCLI
        if fm.fileExists(atPath: cli.path) {
            // whisperCLI = .../whisper.cpp/build/bin/whisper-cli
            let root = cli.deletingLastPathComponent()  // .../build/bin
                .deletingLastPathComponent()           // .../build
                .deletingLastPathComponent()           // .../whisper.cpp
            dirs.append(root.appendingPathComponent("models"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(contentsOf: [
            home.appendingPathComponent("whisper.cpp/models"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents")
        ])

        var found: [String: URL] = [:]
        for dir in dirs where fm.fileExists(atPath: dir.path) {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            for file in files
            where file.pathExtension == "bin"
               && file.lastPathComponent.hasPrefix("ggml-") {
                let id = String(
                    file.lastPathComponent
                        .dropFirst("ggml-".count)
                        .dropLast(".bin".count)
                )
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
            let lines = existingModels.keys.sorted().map { id -> String in
                let url = existingModels[id]!
                return "  • ggml-\(id).bin  (\(humanSize(fileSize(at: url))))"
            }
            scanResultLabel.stringValue =
                "✅ 已在本机发现以下模型（点「使用此模型」即可，无需下载）：\n" +
                lines.joined(separator: "\n")
            scanResultLabel.textColor = .systemGreen
        }
    }

    /// 智能默认选中：① AppConfig 已存模型 → ② 扫描到的第一个 → ③ large-v3
    private func applySmartSelection() {
        let configured = AppConfig.shared.whisperModel
        if FileManager.default.fileExists(atPath: configured.path) {
            let name = configured.lastPathComponent
            if name.hasPrefix("ggml-") && name.hasSuffix(".bin") {
                let id = String(name.dropFirst("ggml-".count).dropLast(".bin".count))
                if let idx = MODEL_INFO.firstIndex(where: { $0.id == id }) {
                    popup.selectItem(at: idx); updateInfo(); return
                }
            }
        }
        if let firstId = existingModels.keys.sorted().first,
           let idx = MODEL_INFO.firstIndex(where: { $0.id == firstId }) {
            popup.selectItem(at: idx)
        } else if let idx = MODEL_INFO.firstIndex(where: { $0.id == "large-v3" }) {
            popup.selectItem(at: idx)
        }
        updateInfo()
    }

    // MARK: - 按钮 / 状态联动

    /// 按"选中档位是否已存在"刷新按钮文案与状态行。
    private func refreshActionButton() {
        guard let item = MODEL_INFO[safe: popup.indexOfSelectedItem] else { return }
        if let existing = existingModels[item.id] {
            actionBtn.title = "使用此模型"
            statusLabel.stringValue =
                "✅ 已就绪 · ggml-\(item.id).bin (\(humanSize(fileSize(at: existing))))"
        } else {
            actionBtn.title = "下载所选模型"
            statusLabel.stringValue = "未下载 · ggml-\(item.id).bin"
        }
        progressBar.doubleValue = 0
    }

    private func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func humanSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    private func updateInfo() {
        guard let item = MODEL_INFO[safe: popup.indexOfSelectedItem] else { return }
        infoLabel.stringValue = "文件名：ggml-\(item.id).bin · 约 \(item.approxMB) MB"
    }

    @objc private func modelSelected() {
        updateInfo()
        refreshActionButton()
    }

    /// 智能按钮：已存在 → 直接采用；不存在 → 下载。
    @objc private func actionButtonClicked() {
        guard let item = MODEL_INFO[safe: popup.indexOfSelectedItem] else { return }
        if let existing = existingModels[item.id] {
            useExistingModel(existing)
        } else {
            startDownload()
        }
    }

    /// 把已扫描到的模型登记为"使用中"，写入 AppConfig。
    private func useExistingModel(_ url: URL) {
        AppConfig.shared.whisperModel = url
        statusLabel.stringValue = "✅ 已采用：\(url.lastPathComponent) (\(humanSize(fileSize(at: url))))"
        progressBar.doubleValue = 100
    }

    /// 手动浏览本机已有的 ggml 模型文件：避免用户重复下载（尤其是 ~3GB 的 large-v3）。
    @objc private func browseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["bin"]
        panel.allowsOtherFileTypes = false
        panel.directoryURL = AppConfig.shared.whisperModel.deletingLastPathComponent()
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            guard url.pathExtension == "bin", url.lastPathComponent.hasPrefix("ggml-") else {
                self?.presentError("请选择以 ggml- 开头、扩展名为 .bin 的 whisper 模型文件。")
                return
            }
            let id = String(url.lastPathComponent
                .dropFirst("ggml-".count)
                .dropLast(".bin".count))
            AppConfig.shared.whisperModel = url
            self?.existingModels[id] = url
            self?.renderScanResult()
            if let idx = self?.MODEL_INFO.firstIndex(where: { $0.id == id }) {
                self?.popup.selectItem(at: idx)
            }
            self?.updateInfo()
            self?.refreshActionButton()
            self?.useExistingModel(url)   // 直接采用本机文件，无需下载
        }
    }

    @objc private func startDownload() {
        guard let item = MODEL_INFO[safe: popup.indexOfSelectedItem] else { return }
        let modelsDir = AppConfig.shared.whisperCLI
            .deletingLastPathComponent()          // .../build/bin
            .deletingLastPathComponent()          // .../build
            .deletingLastPathComponent()          // .../whisper.cpp
            .appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let dest = modelsDir.appendingPathComponent("ggml-\(item.id).bin")
        destination = dest
        AppConfig.shared.whisperModel = dest

        let url = URL(string: MODEL_BASE_URL + "ggml-\(item.id).bin")!
        statusLabel.stringValue = "准备下载…"
        actionBtn.isEnabled = false
        let task = session.downloadTask(with: url)
        task.resume()
    }

    // MARK: URLSessionDownloadDelegate（delegateQueue = main，回调在主线程）

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressBar.doubleValue = frac * 100
        statusLabel.stringValue = String(format: "下载中… %.0f%%", frac * 100)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let dest = destination else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            // 登记到现有模型，刷新扫描结果 + 按钮
            if let item = MODEL_INFO[safe: popup.indexOfSelectedItem] {
                existingModels[item.id] = dest
                renderScanResult()
                refreshActionButton()
            }
        } catch {
            statusLabel.stringValue = "❌ 保存失败：\(error.localizedDescription)"
        }
        actionBtn.isEnabled = true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            statusLabel.stringValue = "❌ 下载失败：\(error.localizedDescription)"
            actionBtn.isEnabled = true
        }
    }

    private func presentError(_ msg: String) {
        AppAlert.show(message: "无法继续", informative: msg, icon: .error)
    }
}

// MARK: - Step 3：工作目录

final class Step3DirectoryView: WizardStepView {

    override var title: String { "工作目录" }
    override var subtitle: String { "所有原始录音、转写、纪要、脱敏缓存都存放在此目录（MM_BASE_DIR）" }

    private let pathField = NSTextField(labelWithString: "")
    private let createSubdirs = NSButton(checkboxWithTitle: "创建标准子目录结构（001-006）", target: nil, action: nil)

    override func buildUI() {
        contentStack.addArrangedSubview(makeLabel(
            "建议保留默认位置（文稿 / MeetingMinutes）。该目录会被写入大量中间文件，请选择有充足空间的磁盘。", size: 12))

        pathField.stringValue = AppConfig.shared.baseDir.path
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.preferredMaxLayoutWidth = 480
        contentStack.addArrangedSubview(pathField)

        let choose = makeButton("选择目录…", target: self, action: #selector(chooseDir))
        contentStack.addArrangedSubview(choose)

        createSubdirs.state = .on
        contentStack.addArrangedSubview(createSubdirs)

        validate = { [weak self] in self?.AppConfig_shared.isBaseDirPresent ?? false }
        showValidationError = { [weak self] in
            self?.presentError("请选择一个存在的目录作为工作目录。")
        }
    }

    private var AppConfig_shared: AppConfig { AppConfig.shared }

    @objc private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            AppConfig.shared.baseDir = url
            self?.pathField.stringValue = url.path
            if self?.createSubdirs.state == .on {
                self?.createStandardSubdirs(at: url)
            }
        }
    }

    private func createStandardSubdirs(at base: URL) {
        // 必须与 pipeline.py 的 Config 目录名完全一致（001_Audio/002_Transcript/003_Meeting_Minutes/
        // 004_Desensitize_Cache/005_LLMWiKi），否则丢进去的音频/输出 pipeline 找不到。
        let names = ["001_Audio", "002_Transcript", "003_Meeting_Minutes",
                     "004_Desensitize_Cache", "005_LLMWiKi"]
        for n in names {
            try? FileManager.default.createDirectory(at: base.appendingPathComponent(n),
                                                     withIntermediateDirectories: true)
        }
        // RAG 仅索引 005_LLMWiKi/knowledge_base，需提前建好
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("005_LLMWiKi").appendingPathComponent("knowledge_base"),
            withIntermediateDirectories: true)
        appendLog("已创建标准子目录：\(names.joined(separator: ", "))")
    }

    private func appendLog(_ text: String) {
        print("[SetupWizard] \(text)")
    }

    private func presentError(_ msg: String) {
        AppAlert.show(message: "无法继续", informative: msg, icon: .error)
    }
}

// MARK: - Step 4：大模型供应商

final class Step4LLMView: WizardStepView {

    override var title: String { "大模型" }
    override var subtitle: String { "选择供应商并填入 API Key（仅存于系统钥匙串，绝不明文落盘）" }

    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyField = NSSecureTextField()
    private let baseURLField = NSTextField()

    override func buildUI() {
        contentStack.addArrangedSubview(makeLabel(
            "API Key 仅写入 macOS 钥匙串（服务名 com.weilu.meetingminutes），应用重启后自动读取，不会写入任何文件。", size: 12))

        providerPopup.addItems(withTitles: ["Gemini", "OpenAI"])
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        contentStack.addArrangedSubview(formRow("供应商", providerPopup))

        contentStack.addArrangedSubview(formRow("模型", modelPopup))
        refreshModels()

        keyField.placeholderString = "粘贴你的 API Key"
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        contentStack.addArrangedSubview(formRow("API Key", keyField))

        baseURLField.placeholderString = "可选：OpenAI 兼容服务的 Base URL"
        baseURLField.translatesAutoresizingMaskIntoConstraints = false
        baseURLField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        contentStack.addArrangedSubview(formRow("Base URL", baseURLField))

        let save = makeButton("保存密钥到钥匙串", target: self, action: #selector(saveKey))
        contentStack.addArrangedSubview(save)

        // 回填已保存的值（若有）
        let cfg = AppConfig.shared
        providerPopup.selectItem(withTitle: cfg.llmProvider == .gemini ? "Gemini" : "OpenAI")
        providerChanged()
        if let existing = cfg.apiKey() { keyField.stringValue = existing }
        if let url = cfg.openAIBaseURL { baseURLField.stringValue = url }

        validate = {
            AppConfig.shared.apiKey().map { !$0.isEmpty } ?? false
        }
        showValidationError = { [weak self] in
            self?.presentError("请先填入 API Key 并点击「保存密钥到钥匙串」。")
        }
    }

    @objc private func providerChanged() {
        let isGemini = providerPopup.titleOfSelectedItem == "Gemini"
        AppConfig.shared.llmProvider = isGemini ? .gemini : .openai
        baseURLField.isHidden = isGemini
        refreshModels()
    }

    private func refreshModels() {
        modelPopup.removeAllItems()
        if AppConfig.shared.llmProvider == .gemini {
            // gemini-2.5-flash / 2.5-pro / 2.0-flash 自 2026 年起对新用户停用（返回 404），仅保留 Gemini 3.x 可用项
            modelPopup.addItems(withTitles: ["gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-3.6-flash"])
        } else {
            modelPopup.addItems(withTitles: ["gpt-4o-mini", "gpt-4o", "gpt-4-turbo"])
        }
        let cfg = AppConfig.shared
        if modelPopup.itemTitles.contains(cfg.llmModel) {
            modelPopup.selectItem(withTitle: cfg.llmModel)
        }
    }

    @objc private func saveKey() {
        let cfg = AppConfig.shared
        cfg.llmModel = modelPopup.titleOfSelectedItem ?? cfg.llmModel
        if !baseURLField.stringValue.isEmpty {
            cfg.openAIBaseURL = baseURLField.stringValue
        }
        cfg.setAPIKey(keyField.stringValue)
        AppAlert.show(
            message: "已保存",
            informative: "API Key 已写入系统钥匙串（\(cfg.llmProvider.rawValue)）。",
            icon: .save
        )
    }

    private func presentError(_ msg: String) {
        AppAlert.show(message: "无法继续", informative: msg, icon: .error)
    }
}

// MARK: - Step 5：Python 引擎（定位 + 依赖安装）

final class StepPythonEngineView: WizardStepView {

    override var title: String { "Python 引擎" }
    override var subtitle: String { "定位 Python 3.11+ 并安装纪要依赖（numpy / pypinyin / sentence-transformers / google-genai / openai）" }

    private let pathField = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let depsLabel = NSTextField(labelWithString: "")
    private let logView = NSTextView()
    private let scroll = NSScrollView()
    private var installProcess: Process?
    private var depsOK = false

    override func buildUI() {
        contentStack.addArrangedSubview(makeLabel(
            "Meetinsight 的纪要后处理（脱敏 / 向量检索 / 大模型调用）由 Python 引擎完成。向导会检测本机 Python 与依赖；若缺失，可点「浏览」指定，或点「安装依赖」自动 pip 安装。", size: 12))

        pathField.stringValue = AppConfig.shared.pythonExecutable.path
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.preferredMaxLayoutWidth = 480
        contentStack.addArrangedSubview(formRow("Python", pathField))

        contentStack.addArrangedSubview(versionLabel)
        contentStack.addArrangedSubview(depsLabel)

        let browse = makeButton("浏览 Python…", target: self, action: #selector(browsePython))
        let install = makeButton("安装依赖", target: self, action: #selector(installDeps))
        let h = NSStackView(views: [browse, install])
        h.spacing = 10
        contentStack.addArrangedSubview(h)

        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = NSColor.textBackgroundColor
        scroll.documentView = logView
        contentStack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 120)
        ])

        validate = { [weak self] in self?.depsOK ?? false }
        showValidationError = { [weak self] in
            self?.presentError("Python 依赖未就绪。请点击「安装依赖」自动安装，或确认本机 Python 3.11+ 已含 numpy / sentence-transformers / google-genai / openai / pypinyin。")
        }

        detect()
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            self.logView.string += text + "\n"
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    /// 后台检测 Python 版本与核心依赖是否齐全。
    private func detect() {
        versionLabel.stringValue = "检测中…"
        depsLabel.stringValue = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let py = AppConfig.shared.pythonExecutable.path
            let (c1, o1) = runProcess(py, ["--version"])
            let ver = c1 == 0 ? o1 : "未找到（退出码 \(c1)）"
            let (c2, o2) = runProcess(py, ["-c", "import numpy, pypinyin, sentence_transformers, google.genai, openai; print('OK')"])
            let ok = (c2 == 0)
            DispatchQueue.main.async {
                self?.depsOK = ok
                self?.versionLabel.stringValue = "版本：\(ver)"
                self?.depsLabel.stringValue = ok
                    ? "✅ 核心依赖已就绪（numpy / pypinyin / sentence-transformers / google-genai / openai）"
                    : "⚠️ 依赖缺失：\(o2.isEmpty ? "请点击「安装依赖」" : o2)"
                self?.depsLabel.textColor = ok ? .systemGreen : .secondaryLabelColor
            }
        }
    }

    @objc private func browsePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            AppConfig.shared.pythonExecutable = url
            self?.pathField.stringValue = url.path
            self?.detect()
        }
    }

    @objc private func installDeps() {
        let py = AppConfig.shared.pythonExecutable.path
        let req = AppConfig.shared.pipelineScript
            .deletingLastPathComponent().appendingPathComponent("requirements.txt").path
        guard FileManager.default.fileExists(atPath: req) else {
            appendLog("⚠️ 未找到 requirements.txt：\(req)")
            return
        }
        appendLog("将执行：\(py) -m pip install -r \(req)")
        let script = "\(py) -m pip install -r '\(req)'"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let data = h.availableData.nonEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(s.trimmingCharacters(in: .newlines))
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    self?.appendLog("✅ 依赖安装完成。")
                } else {
                    self?.appendLog("❌ 安装失败，退出码 \(p.terminationStatus)。")
                }
                self?.detect()
            }
        }
        installProcess = proc
        try? proc.run()
    }

    private func presentError(_ msg: String) {
        AppAlert.show(message: "无法继续", informative: msg, icon: .error)
    }
}

// MARK: - Step 6：bge-small-zh-v1.5 嵌入模型

final class StepEmbeddingModelView: WizardStepView {

    override var title: String { "嵌入模型 · RAG 语义检索" }
    override var subtitle: String { "会议纪要的 Wiki 知识库用 bge-small-zh-v1.5 做语义向量；可现在下载（约 90MB，存本机），或跳过（不使用 RAG，Wiki 检索降级为关键词匹配）；如本机已有模型文件夹，也可直接「浏览本机嵌入模型…」指定。" }

    private let statusLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let logView = NSTextView()
    private let scroll = NSScrollView()
    private var downloadProcess: Process?
    private var modelReady = false
    private var skipped = false

    private let modelID = "BAAI/bge-small-zh-v1.5"
    /// 下载落点：沙箱容器可写的 Caches/huggingface/bge-small-zh-v1.5（扁平、无软链，
    /// SentenceTransformer 可直接加载）。沙箱禁止写 ~/.cache，故必须走这里。
    private let downloadDir: URL = {
        AppConfig.shared.huggingfaceHome.appendingPathComponent("bge-small-zh-v1.5")
    }()
    /// 已知国内 CDN 镜像（Hugging Face 的官方推荐替代，无需科学上网，文件结构与 HF 完全一致）
    private let mirrorEndpoint = "https://hf-mirror.com"

    override func buildUI() {
        contentStack.addArrangedSubview(makeLabel(
            "该模型仅用于本地语义检索（把 Wiki 知识库切成向量，会议时按语义匹配背景资料），不会上传。向导会先检测本机是否已有缓存。", size: 12))

        // 科学上网 / 国内镜像提示（关键：用户截图反馈默认走 HF 直连会失败）
        let notice = makeLabel(
            "⚠️ 默认下载源 huggingface.co 在国内需要科学上网。若无法科学上网，请：\n" +
            "  ① 点「下载（国内镜像 hf-mirror.com）」按钮（一键切到国内 CDN，无需 VPN）；或\n" +
            "  ② 点「浏览本机嵌入模型…」手动指定本机已有的 bge-small-zh-v1.5 目录（含 config.json + model.safetensors），\n" +
            "     例如 ~/.cache/huggingface/hub/models--BAAI--bge-small-zh-v1.5/snapshots/<hash>/；或自行从 hf-mirror.com 下载后的解压目录。",
            size: 11)
        notice.textColor = .systemOrange
        notice.maximumNumberOfLines = 0
        notice.lineBreakMode = .byWordWrapping
        contentStack.addArrangedSubview(notice)

        contentStack.addArrangedSubview(statusLabel)
        contentStack.addArrangedSubview(progressLabel)

        // 第一行：下载 / 跳过
        let download = makeButton("下载模型（HuggingFace 直连，需科学上网）",
                                  target: self, action: #selector(downloadModelDefault))
        let skip = makeButton("跳过（不使用 RAG）", target: self, action: #selector(skipModel))
        let row1 = NSStackView(views: [download, skip])
        row1.spacing = 10
        contentStack.addArrangedSubview(row1)

        // 第二行：国内镜像 / 浏览本机
        let mirror = makeButton("下载（国内镜像 hf-mirror.com，免 VPN）",
                                target: self, action: #selector(downloadModelMirror))
        let browse = makeButton("浏览本机嵌入模型…", target: self, action: #selector(browseLocalModel))
        let row2 = NSStackView(views: [mirror, browse])
        row2.spacing = 10
        contentStack.addArrangedSubview(row2)

        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = NSColor.textBackgroundColor
        scroll.documentView = logView
        contentStack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 120)
        ])

        // 本步骤不强制：模型已就绪 或 用户选择跳过 均可前进
        validate = { [weak self] in (self?.modelReady ?? false) || (self?.skipped ?? false) }
        showValidationError = { [weak self] in
            self?.presentError("请先「下载模型」（国内推荐用国内镜像按钮，免 VPN），或「浏览本机嵌入模型…」指定本机已有的目录；也可「跳过（不使用 RAG）」。")
        }

        detect()
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            self.logView.string += text + "\n"
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    private func detect() {
        // 1) 用户显式指定 → 就绪
        if let p = AppConfig.shared.embeddingModelPath, FileManager.default.fileExists(atPath: p.path) {
            modelReady = true
            statusLabel.stringValue = "✅ 已采用本机嵌入模型：\(p.path)"
            statusLabel.textColor = .systemGreen
            progressLabel.stringValue = "可直接进入下一步；若不打算用 RAG，也可点「跳过」。"
            return
        }
        // 2) 下载落点（沙箱 Caches/huggingface/bge-small-zh-v1.5）含权重 → 就绪
        let hasWeights = FileManager.default.fileExists(atPath: downloadDir.appendingPathComponent("model.safetensors").path)
                       || FileManager.default.fileExists(atPath: downloadDir.appendingPathComponent("pytorch_model.bin").path)
        modelReady = hasWeights
        if hasWeights {
            statusLabel.stringValue = "✅ 已就绪：bge-small-zh-v1.5（位于 \(downloadDir.path)）。"
            statusLabel.textColor = .systemGreen
            progressLabel.stringValue = "可直接进入下一步；若不打算用 RAG，也可点「跳过」。"
        } else {
            statusLabel.stringValue = "🔍 未检测到 bge-small-zh-v1.5（本机无缓存、也未下载）。"
            statusLabel.textColor = .secondaryLabelColor
            progressLabel.stringValue = "推荐点「下载（国内镜像）」或「浏览本机嵌入模型…」；或「跳过」。"
        }
    }

    private func humanCacheSize() -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: downloadDir.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return "未知大小" }
        let mb = Double(size) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    // MARK: 下载入口（默认 = HF 直连）
    @objc private func downloadModelDefault() {
        AppConfig.shared.embeddingUseMirror = false
        runDownload()
    }
    // MARK: 下载入口（国内镜像）
    @objc private func downloadModelMirror() {
        AppConfig.shared.embeddingUseMirror = true
        appendLog("已切换到国内镜像 \(mirrorEndpoint)（无需科学上网）")
        runDownload()
    }
    /// 共享下载逻辑：把模型解包到沙箱可写目录（HF_HOME/bge-small-zh-v1.5），
    /// 用 huggingface_hub.snapshot_download 避免 HF 软链结构；注入 HF_HOME + HF_ENDPOINT 到子进程。
    private func runDownload() {
        // 清掉可能残留的本地路径（这次走下载）
        AppConfig.shared.embeddingModelPath = nil
        let useMirror = AppConfig.shared.embeddingUseMirror
        let py = AppConfig.shared.pythonExecutable.path
        let src = useMirror ? "国内镜像 \(mirrorEndpoint)" : "HuggingFace 直连（需科学上网）"
        appendLog("将下载 \(modelID)（首次需联网，约 90MB，源：\(src)）…")
        progressLabel.stringValue = "下载中…（进度见日志，源：\(src)）"

        // 用 huggingface_hub 直接解包到沙箱可写目录（扁平、无软链），SentenceTransformer 可直接加载
        let localDir = downloadDir.path
        let pyScript = """
from huggingface_hub import snapshot_download
p = snapshot_download(\"\(modelID)\", local_dir=\(shellQuote(localDir)), local_dir_use_symlinks=False)
print("LOCAL_DIR=" + p)
"""
        let script = "\(shellQuote(py)) -c \(shellQuote(pyScript))"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        // 注入网络/缓存环境变量（沙箱默认禁网，需 entitlements 开 network.client）
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = AppConfig.shared.huggingfaceHome.path
        if useMirror { env["HF_ENDPOINT"] = mirrorEndpoint }
        proc.environment = env
        proc.arguments = ["-c", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let data = h.availableData.nonEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(s.trimmingCharacters(in: .newlines))
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    // 下载落点即我们指定的扁平目录，自动「采用」
                    AppConfig.shared.embeddingModelPath = self?.downloadDir
                    self?.skipped = false
                    self?.appendLog("✅ 模型已下载到：\(self?.downloadDir.path ?? "")")
                    self?.detect()
                } else {
                    let hint = useMirror
                        ? "国内镜像也失败，请检查网络后重试；或点「浏览本机嵌入模型…」指定本机已有目录；或「跳过」。"
                        : "HuggingFace 直连失败（国内通常需要科学上网），请改点「下载（国内镜像 hf-mirror.com）」；或「浏览本机嵌入模型…」；或「跳过」。"
                    self?.appendLog("❌ 下载失败，退出码 \(p.terminationStatus)。\(hint)")
                }
            }
        }
        downloadProcess = proc
        try? proc.run()
    }

    // MARK: 浏览本机嵌入模型（NSOpenPanel 选目录，校验 config.json + model.safetensors）
    @objc private func browseLocalModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = AppConfig.shared.embeddingModelPath ?? downloadDir
        panel.message = "请选择含 bge-small-zh-v1.5 模型文件的目录（必须包含 config.json + model.safetensors 或 pytorch_model.bin）"
        panel.prompt = "采用此目录"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            guard Self.isValidEmbeddingDir(url) else {
                self?.presentError("所选目录不是有效的 bge-small-zh-v1.5 模型目录（需要 config.json + model.safetensors/pytorch_model.bin）。")
                return
            }
            AppConfig.shared.embeddingModelPath = url
            AppConfig.shared.embeddingModelSkipped = false
            self?.skipped = false
            self?.appendLog("✅ 已采用本机嵌入模型：\(url.path)")
            self?.detect()
        }
    }

    /// 校验目录是否含 bge-small-zh-v1.5 的最小可加载文件集。
    /// 同时支持两种目录形式：① 解压后的模型根目录；② HF 缓存 snapshots/<hash>/ 子目录。
    private static func isValidEmbeddingDir(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let required = ["config.json"]
        let weights = ["model.safetensors", "pytorch_model.bin", "pytorch_model.bin.index.json",
                       "model.safetensors.index.json"]
        for f in required {
            if !fm.fileExists(atPath: dir.appendingPathComponent(f).path) { return false }
        }
        for w in weights {
            if fm.fileExists(atPath: dir.appendingPathComponent(w).path) { return true }
        }
        return false
    }

    @objc private func skipModel() {
        skipped = true
        AppConfig.shared.embeddingModelSkipped = true
        // 同时清掉本机路径，避免 pipeline 同时拿到两边信号
        AppConfig.shared.embeddingModelPath = nil
        statusLabel.stringValue = "⏭️ 已跳过嵌入模型；RAG 语义检索将停用（Wiki 检索降级为关键词匹配）。"
        statusLabel.textColor = .systemOrange
        progressLabel.stringValue = "可继续下一步。"
    }

    private func presentError(_ msg: String) {
        AppAlert.show(message: "无法继续", informative: msg, icon: .error)
    }
}

/// 给 Python 路径做 shell-safe 引号转义（处理含空格/特殊字符的路径）。
fileprivate func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - 小工具

fileprivate extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

fileprivate extension Data {
    /// 非空时返回 self，否则 nil（readabilityHandler 可能给空包）
    var nonEmpty: Data? { isEmpty ? nil : self }
}
