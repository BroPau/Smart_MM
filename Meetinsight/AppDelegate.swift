//
//  AppDelegate.swift
//  Meetinsight
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    /// 强引用向导控制器，避免窗口被关闭前控制器被释放。
    private var setupWizard: SetupWizardWindowController?
    /// 主窗口引用（单窗口分页容器）。
    private var mainWindow: NSWindow?
    /// 主容器控制器（分页切换 / 菜单调用）。
    private var mainContainer: MainContainerViewController?
    /// 退出确认标记：由红 X 路径确认过退出后，避免 applicationShouldTerminate 二次弹框。
    private var exitConfirmed = false

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // v2.2.13：先恢复对工作目录的 sandbox 授权（解析持久化 security-scoped bookmark）。
        // 必须在 isConfigured（依赖 FileManager.fileExists 探测 baseDir）之前调用，
        // 否则 sandbox 下 fileExists 永远返回 false，会反复把已配置用户踢回向导。
        let accessOK = AppConfig.shared.startAccessingBaseDir()

        if !AppConfig.shared.isConfigured {
            let wizard = SetupWizardWindowController()
            setupWizard = wizard
            wizard.showWindow(nil)
            wizard.window?.center()
            wizard.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            NotificationCenter.default.addObserver(
                forName: .setupWizardDidFinish,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // 向导结束时再次确保授权（Step3 刚写入 bookmark）。
                AppConfig.shared.startAccessingBaseDir()
                self?.setupWizard = nil
                self?.showMainWindow()
            }
        } else {
            showMainWindow()
        }

        // 已配置但授权恢复失败（目录被删 / 旧安装无 bookmark）：一次性引导到「设置 → 重设工作目录」。
        if AppConfig.shared.isConfigured && !accessOK {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                AppAlert.show(
                    message: "工作目录访问授权已失效",
                    informative: "App 已无法读取「\(AppConfig.shared.baseDir.path)」。\n\n请打开「设置 → 工作目录 → 重设工作目录…」重新选择该目录即可恢复（无需重装）。",
                    icon: .warning,
                    style: .warning,
                    buttons: ["知道了"]
                )
            }
        }
    }

    /// 显示主窗口（单窗口分页：纪要生成 / LLM WiKi / 设置）。
    private func showMainWindow() {
        // 确保对工作目录的 sandbox 授权已激活（重复调用由 AppConfig 内部 isBaseDirAccessing 守卫）。
        AppConfig.shared.startAccessingBaseDir()
        if mainWindow == nil {
            // 默认窗口大小：以「能完整显示 WiKi 首页左右式预览」为目标；
            // 用户调整过的尺寸会写入 UserDefaults,下次启动沿用。
            let defaults = UserDefaults.standard
            let width  = CGFloat((defaults.object(forKey: "MM_WINDOW_WIDTH")  as? Double) ?? 1280)
            let height = CGFloat((defaults.object(forKey: "MM_WINDOW_HEIGHT") as? Double) ?? 820)
            let minW: CGFloat = 1100, minH: CGFloat = 720

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Meetinsight"
            window.minSize = NSSize(width: minW, height: minH)
            window.isReleasedWhenClosed = false
            window.delegate = self
            let container = MainContainerViewController()
            window.contentViewController = container
            mainContainer = container
            installMainMenu()
            // 中心化显示
            if let screen = NSScreen.main {
                let sf = screen.visibleFrame
                let x = sf.origin.x + (sf.width  - width)  / 2
                let y = sf.origin.y + (sf.height - height) / 2
                window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            } else {
                window.center()
            }
            // 监听窗口尺寸变化,持久化以便下次启动沿用
            let nc = NotificationCenter.default
            nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                let f = window.frame
                defaults.set(Double(f.width),  forKey: "MM_WINDOW_WIDTH")
                defaults.set(Double(f.height), forKey: "MM_WINDOW_HEIGHT")
            }
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // 退出前终止可能仍在运行的 pipeline 子进程（如生成任务被强制结束）。
        PipelineRunner.shared.cancel()
        // 释放对工作目录的 sandbox 授权（与 applicationDidFinishLaunching 的 start 配对）。
        AppConfig.shared.stopAccessingBaseDir()
    }

    /// 关闭主窗口后，点击 Dock 图标重新唤起（#2）。
    /// 窗口已设 `isReleasedWhenClosed = false`，故实例仍在，仅需再次前置显示。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow == nil {
            showMainWindow()
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - 关窗 / 退出拦截（生成任务进行中提醒）

    /// 生成任务进行中时，询问用户是否确认退出。
    /// - Returns: `true` 表示用户确认退出；`false` 表示取消（继续运行）。
    private func confirmExitWhileGenerating() -> Bool {
        let resp = AppAlert.show(
            message: "任务进行中",
            informative: "生成会议纪要正在进行，退出将中断当前任务。确定要退出吗？",
            icon: .question,
            style: .warning,
            buttons: ["取消", "退出"]
        )
        // AppAlert.show 返回第一个按钮（「取消」）对应的 .alertFirstButtonReturn；
        // 用户点击「退出」（第二个按钮）才视为确认。
        return resp != .alertFirstButtonReturn
    }

    /// 点击窗口红 X：若纪要正在生成，先询问是否退出，避免误关中断任务。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard mainContainer?.isMinutesGenerating == true else { return true }
        if confirmExitWhileGenerating() {
            exitConfirmed = true
            NSApp.terminate(nil)   // 交回 applicationShouldTerminate 处理（已设 exitConfirmed，不二次弹框）
            return false
        }
        return false               // 取消退出：保持窗口
    }

    /// Cmd+Q / 菜单「退出」：若纪要正在生成，先询问是否退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainContainer?.isMinutesGenerating == true else { return .terminateNow }
        if exitConfirmed { return .terminateNow }   // 红 X 路径已确认过，避免重复弹框
        return confirmExitWhileGenerating() ? .terminateNow : .terminateCancel
    }

    // MARK: - 主菜单（含标准 Edit 菜单，确保系统快捷键可用）

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单
        let appMenu = NSMenu(title: "Meetinsight")
        let appItem = NSMenuItem(title: "Meetinsight", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        let quitItem = NSMenuItem(title: "退出 Meetinsight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        mainMenu.addItem(appItem)

        // 编辑菜单：把复制/粘贴/全选/撤销等系统快捷键接入响应链（#5）
        let editMenu = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        let undo = NSMenuItem(title: "撤销", action: Selector("undo:"), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector("redo:"), keyEquivalent: "Z")
        let cut = NSMenuItem(title: "剪切", action: Selector("cut:"), keyEquivalent: "x")
        let copy = NSMenuItem(title: "复制", action: Selector("copy:"), keyEquivalent: "c")
        let paste = NSMenuItem(title: "粘贴", action: Selector("paste:"), keyEquivalent: "v")
        let delete = NSMenuItem(title: "删除", action: Selector("delete:"), keyEquivalent: "")
        let selectAll = NSMenuItem(title: "全选", action: Selector("selectAll:"), keyEquivalent: "a")
        for m in [undo, redo, cut, copy, paste, delete, selectAll] {
            m.target = nil  // 交给第一响应者（NSTextView / WKWebView 编辑区）
            editMenu.addItem(m)
            if m === redo || m === cut { editMenu.addItem(.separator()) }
        }
        mainMenu.addItem(editItem)

        // 知识库菜单
        let wikiSub = NSMenu(title: "知识库")
        let openItem = NSMenuItem(title: "打开 LLM WiKi", action: #selector(openWikiTab), keyEquivalent: "")
        let rebuildItem = NSMenuItem(title: "重建 WiKi", action: #selector(rebuildWikiFromMenu), keyEquivalent: "")
        [openItem, rebuildItem].forEach { $0.target = self }
        wikiSub.addItem(openItem)
        wikiSub.addItem(rebuildItem)
        let wikiItem = NSMenuItem(title: "知识库", action: nil, keyEquivalent: "")
        wikiItem.submenu = wikiSub
        mainMenu.addItem(wikiItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openWikiTab() {
        mainContainer?.showWikiTab()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func rebuildWikiFromMenu() {
        mainContainer?.showWikiTab()
        mainContainer?.rebuildWiki()
    }
}
