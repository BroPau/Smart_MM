//
//  AppDelegate.swift
//  Meetinsight
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    /// 强引用向导控制器，避免窗口被关闭前控制器被释放。
    private var setupWizard: SetupWizardWindowController?
    /// 主窗口引用（单窗口分页容器）。
    private var mainWindow: NSWindow?
    /// 主容器控制器（分页切换 / 菜单调用）。
    private var mainContainer: MainContainerViewController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
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
                self?.setupWizard = nil
                self?.showMainWindow()
            }
        } else {
            showMainWindow()
        }
    }

    /// 显示主窗口（单窗口分页：纪要生成 / LLM Wiki / 设置）。
    private func showMainWindow() {
        if mainWindow == nil {
            // 默认窗口大小：以「能完整显示 Wiki 首页左右式预览」为目标；
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
            let container = MainContainerViewController()
            window.contentViewController = container
            mainContainer = container
            installWikiMenu()
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

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - 知识库 Wiki 菜单（切到 LLM Wiki 分页）

    private func installWikiMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let sub = NSMenu(title: "知识库")
        let openItem = NSMenuItem(title: "打开 LLM Wiki", action: #selector(openWikiTab), keyEquivalent: "")
        let rebuildItem = NSMenuItem(title: "重建 Wiki", action: #selector(rebuildWikiFromMenu), keyEquivalent: "")
        [openItem, rebuildItem].forEach { $0.target = self }
        sub.addItem(openItem)
        sub.addItem(rebuildItem)

        let item = NSMenuItem(title: "知识库", action: nil, keyEquivalent: "")
        item.submenu = sub
        mainMenu.addItem(item)
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
