//
//  main.swift
//  Meetinsight
//
//  显式程序入口：明確创建 NSApplication、把 AppDelegate 设为 delegate、
//  声明为 regular 激活策略并 run()。
//
//  这样彻底绕开 `@main` 合成入口在「无 storyboard + 特定 Xcode 构建结构」
//  下可能产生的歧义——直接保证 applicationDidFinishLaunching 一定被调用，
//  从根上解决「进程存活、系统噪声照打、但窗口永不显示」的问题。
//
//  linkd 警告静默: 全局噪声（linkd.autoShortcut / WebContent 'pboard' / TCC 等）
//  是 macOS 在启动任意 GUI App 时由系统框架统一打印的,无法通过 entitlements
//  或代码消除（开发者签名也未必能加）。用户级开关:
//      MM_QUIET_STDERR=1  → 把 stderr 重定向到 /dev/null, 控制台清爽。
//      MM_QUIET_STDERR=0 / 未设 → 保持默认, 便于调试时看到 stderr。
//

import Cocoa
import Foundation
import Darwin   // STDERR_FILENO / dup2

/// 未捕获异常 / 信号处理器：把任何会导致"静默无窗口"的运行时异常，
/// 落盘到 /tmp 并弹出可见告警，便于定位而非无声失败。
private func installFailureHandlers() {
    NSSetUncaughtExceptionHandler { exception in
        let msg = """
        Smart Minutes 未捕获异常：
        \(exception.name.rawValue)
        \(exception.reason ?? "")
        \(exception.callStackSymbols.joined(separator: "\n"))
        """
        try? msg.write(toFile: "/tmp/smm_uncaught.txt", atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = "Smart Minutes 运行时异常"
            a.informativeText = msg
            a.alertStyle = .critical
            a.icon = AppAlertIcon.error.image
            a.runModal()
        }
    }
}

/// stderr 静默: macOS 启动 GUI App 时由系统框架打印的 linkd/pboard/TCC/...
/// 噪声都走 stderr(SetUncaughtExceptionHandler 出来的我们自己的栈仍走 stderr)。
/// 用户显式设定 MM_QUIET_STDERR=1 时把 fd 2 重定向到 /dev/null, 让控制台安静。
/// 注意: 真实崩溃仍会在 Xcode / Console.app 中可见(它们从 os_log 直接读),
///       这只影响终端的 stderr。
private func quietStderrIfRequested() {
    guard ProcessInfo.processInfo.environment["MM_QUIET_STDERR"] == "1" else { return }
    let devnull = open("/dev/null", O_WRONLY)
    guard devnull >= 0 else { return }
    _ = dup2(devnull, STDERR_FILENO)
    close(devnull)
}

let app = NSApplication.shared
quietStderrIfRequested()
installFailureHandlers()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
