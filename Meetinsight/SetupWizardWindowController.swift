//
//  SetupWizardWindowController.swift
//  Meetinsight
//
//  安装向导窗口：承载 4 步视图，负责「上一步 / 下一步 / 完成」导航与步骤指示。
//  完成（或关闭）时发出 .setupWizardDidFinish 通知，供 AppDelegate 接管后续。
//

import Cocoa

@MainActor
final class SetupWizardWindowController: NSWindowController {

    private let steps: [WizardStepView]
    private var current = 0

    private let titleLabel = NSTextField(labelWithString: "")
    private let stepIndicator = NSTextField(labelWithString: "")
    private let containerView = NSView()
    private let backButton = NSButton(title: "上一步", target: nil, action: nil)
    private let nextButton = NSButton(title: "下一步", target: nil, action: nil)
    private let finishButton = NSButton(title: "完成", target: nil, action: nil)

    init() {
        // Swift 两阶段初始化：所有 let 存储属性必须在调用 super.init 之前赋值完毕。
        steps = [Step1RuntimeView(), Step2ModelView(), Step3DirectoryView(), Step4LLMView()]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meetinsight 安装向导"
        super.init(window: window)

        setupUI()
        showStep(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        let pad: CGFloat = 24

        titleLabel.font = NSFont.boldSystemFont(ofSize: 19)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLabel)

        stepIndicator.font = NSFont.systemFont(ofSize: 11)
        stepIndicator.textColor = .secondaryLabelColor
        stepIndicator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stepIndicator)

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        containerView.layer?.cornerRadius = 8
        content.addSubview(containerView)

        for b in [backButton, nextButton, finishButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.bezelStyle = .rounded
            b.target = self
            content.addSubview(b)
        }
        backButton.action = #selector(back)
        nextButton.action = #selector(next)
        finishButton.action = #selector(finish)
        finishButton.keyEquivalent = "\r"
        finishButton.isHidden = true

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),

            stepIndicator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            stepIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            containerView.topAnchor.constraint(equalTo: stepIndicator.bottomAnchor, constant: 12),
            containerView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            containerView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            containerView.bottomAnchor.constraint(equalTo: backButton.topAnchor, constant: -12),

            backButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            backButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),

            nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            nextButton.bottomAnchor.constraint(equalTo: backButton.bottomAnchor),

            finishButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            finishButton.bottomAnchor.constraint(equalTo: backButton.bottomAnchor)
        ])
    }

    private func showStep(_ index: Int) {
        current = index
        let step = steps[index]

        containerView.subviews.forEach { $0.removeFromSuperview() }
        step.embed(in: containerView)

        titleLabel.stringValue = step.title
        stepIndicator.stringValue = "步骤 \(index + 1) / \(steps.count) · \(step.subtitle)"

        backButton.isEnabled = index > 0
        nextButton.isHidden = index == steps.count - 1
        finishButton.isHidden = index != steps.count - 1
    }

    @objc private func back() {
        guard current > 0 else { return }
        showStep(current - 1)
    }

    @objc private func next() {
        guard current < steps.count - 1 else { return }
        if let canAdvance = steps[current].validate?(), !canAdvance {
            steps[current].showValidationError?()
            return
        }
        showStep(current + 1)
    }

    @objc private func finish() {
        let last = steps.last
        if let canFinish = last?.validate?(), !canFinish {
            last?.showValidationError?()
            return
        }
        window?.close()
        NotificationCenter.default.post(name: .setupWizardDidFinish, object: nil)
    }
}

extension Notification.Name {
    static let setupWizardDidFinish = Notification.Name("setupWizardDidFinish")
}
