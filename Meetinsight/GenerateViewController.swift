//
//  GenerateViewController.swift
//  Meetinsight
//
//  纪要生成页（分页 ①）：
//  - 顶部：拖放区 + 选择音频文件 + 开始生成 + 取消 + 进度/状态。
//  - 主体（左右分栏）：左侧 MarkdownEditorView（生成后预览/编辑纪要，支持 [[双链]]）；
//          右侧处理日志。
//  - 编辑后点容器工具栏「保存」写回 003_Meeting_Minutes 最新 .md。
//
//  v2.0 调整：原「📥 导入 RAG 文档」按钮已移至 LLM Wiki 页面，更名为「📥 导入会议纪要」，
//   生成页不再提供导入入口，避免与音频生成场景混淆。
//

import Cocoa
import UniformTypeIdentifiers

final class GenerateViewController: NSViewController {

    private let dropView = DropView()
    private let audioField = NSTextField(labelWithString: "尚未选择音频文件")
    private let pickBtn = NSButton(title: "选择音频文件…", target: nil, action: nil)
    private let runBtn = NSButton(title: "开始生成", target: nil, action: nil)
    private let cancelBtn = NSButton(title: "取消", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let logView = NSTextView()
    private let editor = MarkdownEditorView()

    private var audioURL: URL?
    private var running = false
    /// 当前已生成/正在编辑的纪要文件；保存时写回它。
    private var currentMinutesURL: URL?
    /// 待写回的 URL（保存按钮触发 requestSave 后填充，delegate 回调里落盘）。
    private var pendingSaveURL: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()

        pickBtn.target = self; pickBtn.action = #selector(pickAudio)
        runBtn.target = self; runBtn.action = #selector(runPipeline)
        cancelBtn.target = self; cancelBtn.action = #selector(cancelRun)
        cancelBtn.isEnabled = false

        editor.delegate = self
        dropView.onAudioDropped = { [weak self] url in
            self?.setAudio(url)
        }
    }

    // MARK: - UI

    private func setupUI() {
        let pad: CGFloat = 14

        audioField.preferredMaxLayoutWidth = 220
        audioField.lineBreakMode = .byTruncatingMiddle

        // —— 左侧面板：拖放 + 选文件 + 开始/取消 + 进度 + 状态 + 日志 ——
        audioField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pickBtn.bezelStyle = .rounded
        pickBtn.alignment = .center
        runBtn.bezelStyle = .rounded
        runBtn.alignment = .center
        cancelBtn.bezelStyle = .rounded
        cancelBtn.alignment = .center

        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        // 控件行:左对齐撑开,选文件/开始/取消按钮宽度合理
        for b in [pickBtn, runBtn, cancelBtn] {
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        }
        let controlRow = NSStackView(views: [pickBtn, runBtn, cancelBtn])
        controlRow.orientation = .horizontal
        controlRow.spacing = 8
        controlRow.alignment = .centerY
        controlRow.distribution = .fillEqually
        controlRow.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.isIndeterminate = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let logScroll = makeScrollView(with: logView, font: .monospacedSystemFont(ofSize: 11, weight: .regular))

        let leftStack = NSStackView(views: [
            dropView,
            controlRow,
            progressBar,
            statusLabel,
            sectionLabel("处理日志")
        ])
        leftStack.orientation = .vertical
        leftStack.spacing = 10
        leftStack.alignment = .leading
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        // 让 leftStack 撑出固定宽度
        leftStack.widthAnchor.constraint(equalToConstant: 280).isActive = true
        // 日志区撑出剩余高度
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        leftStack.addArrangedSubview(logScroll)
        logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        // —— 右侧面板：编辑器 + 标题 ——
        let editorTitle = sectionLabel("会议纪要预览（点击进入编辑，保存写回 003_Meeting_Minutes）")
        editorTitle.translatesAutoresizingMaskIntoConstraints = false
        editorTitle.font = NSFont.boldSystemFont(ofSize: 13)

        let rightStack = NSStackView(views: [editorTitle, editor])
        rightStack.orientation = .vertical
        rightStack.spacing = 8
        rightStack.alignment = .leading
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        // —— 整体：左右 NSSplitView（仿 Wiki 风格） ——
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(leftStack)
        split.addArrangedSubview(rightStack)
        // 拆分条位置:左侧占 280
        split.setPosition(280, ofDividerAt: 0)

        view.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: view.topAnchor, constant: pad),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad)
        ])
        editor.load(markdown: "_尚未生成会议纪要。_\n\n选择或拖入一段音频，点击「开始生成」。", editable: false)
    }

    private func makeScrollView(with textView: NSTextView, font: NSFont) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = font
        textView.backgroundColor = NSColor.textBackgroundColor
        scroll.documentView = textView
        return scroll
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.boldSystemFont(ofSize: 12)
        return f
    }

    // MARK: - 动作

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
            presentError("请先选择一段音频文件（或拖入）。")
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
            presentError("无法复制音频到工作目录：\(error.localizedDescription)")
            return
        }

        running = true
        runBtn.isEnabled = false
        cancelBtn.isEnabled = true
        progressBar.doubleValue = 0
        statusLabel.stringValue = "启动中…"
        logView.string = ""
        editor.load(markdown: "_生成中…_", editable: false)

        PipelineRunner.shared.run(
            arguments: ["--json-log"],
            progress: { [weak self] p in self?.handleProgress(p) },
            completion: { [weak self] result in self?.handleCompletion(result) }
        )
    }

    private func handleProgress(_ p: PipelineProgress) {
        if let prog = p.progress { progressBar.doubleValue = prog * 100 }
        statusLabel.stringValue = (p.step.map { "[\($0)] " } ?? "") + p.message
        appendLog("[\(p.level)] \(p.message)")
    }

    private func handleCompletion(_ result: PipelineResult) {
        running = false
        runBtn.isEnabled = true
        cancelBtn.isEnabled = false

        if let error = result.error {
            appendLog("❌ 失败：\(error.localizedDescription)")
            statusLabel.stringValue = "失败"
            presentError("生成失败：\(error.localizedDescription)")
            return
        }

        let minutesDir = AppConfig.shared.baseDir.appendingPathComponent("003_Meeting_Minutes")
        if let md = newestMarkdown(in: minutesDir),
           let text = try? String(contentsOf: md, encoding: .utf8) {
            currentMinutesURL = md
            editor.load(markdown: text, editable: true)
            statusLabel.stringValue = "完成 · \(md.lastPathComponent)"
            appendLog("✅ 已生成：\(md.lastPathComponent)")
        } else {
            appendLog("⚠️ 未在 003_Meeting_Minutes 找到纪要文件。")
            statusLabel.stringValue = "完成（未找到纪要）"
        }
    }

    @objc private func cancelRun() {
        PipelineRunner.shared.cancel()
        appendLog("⏹ 已请求取消")
    }

    // MARK: - 供容器工具栏「保存」调用

    /// 写回当前纪要编辑：触发编辑器保存，落盘在 delegate 回调完成。
    func saveCurrent() {
        guard currentMinutesURL != nil else {
            presentError("尚无已生成的纪要可保存。")
            return
        }
        pendingSaveURL = currentMinutesURL
        editor.requestSave()
    }

    // MARK: - MarkdownEditorViewDelegate

    private func appendLog(_ s: String) {
        logView.string += s + "\n"
        logView.scrollToEndOfDocument(nil)
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

    private func presentError(_ msg: String) {
        AppAlert.show(message: "提示", informative: msg, icon: .warning)
    }
}

// MARK: - MarkdownEditorViewDelegate / SaveablePage

extension GenerateViewController: MarkdownEditorViewDelegate, SaveablePage {
    func markdownEditorDidRequestSave(_ editor: MarkdownEditorView, markdown: String) {
        guard let url = pendingSaveURL else { return }
        pendingSaveURL = nil
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            appendLog("💾 已保存纪要：\(url.lastPathComponent)")
            statusLabel.stringValue = "已保存 · \(url.lastPathComponent)"
        } catch {
            appendLog("❌ 保存失败：\(error.localizedDescription)")
            presentError("保存纪要失败：\(error.localizedDescription)")
        }
    }

    func markdownEditorDidClickWikilink(_ editor: MarkdownEditorView, name: String) {
        // 纪要预览中的双链暂不直接跳转（避免离开生成页）；忽略即可。
        appendLog("ℹ️ 双链（仅预览）：\(name)")
    }

    func markdownEditorRequestsPageList(_ editor: MarkdownEditorView) -> [String] {
        // 纪要页没有 Wiki 页面列表；返回空即可（双链自动完成/缺失判定在该上下文无意义）。
        []
    }

    func markdownEditorPreviewForWikilink(_ editor: MarkdownEditorView, name: String) -> String? {
        nil
    }
}

// MARK: - 拖放区

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
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
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
