//
//  AppAlert.swift
//  Meetinsight
//
//  统一的 NSAlert 封装：为所有「弹出式通知 / 对话框」提供一致的图标。
//
//  背景：原先的 NSAlert 没有显式设置 icon，会回退到 App 的默认图标；
//  当 AppIcon 资源缺失时，弹窗就会出现「破图」。本文件改用 SF Symbols
//  （系统字体渲染，零外部资源依赖，始终可用），从根本上消除破图问题，
//  同时满足「给弹出式通知一个图标」的需求。
//

import Cocoa

/// 弹出式通知的图标集合（SF Symbols）。
enum AppAlertIcon: String {
    case info     // 信息
    case warning  // 警告
    case error    // 错误
    case question // 询问 / 确认
    case wiki     // 知识库 / Wiki
    case save     // 保存
    case success  // 成功

    private var symbolName: String {
        switch self {
        case .info:     return "info.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .error:    return "xmark.octagon.fill"
        case .question: return "questionmark.circle.fill"
        case .wiki:     return "books.vertical.fill"
        case .save:     return "tray.and.arrow.down.fill"
        case .success:  return "checkmark.circle.fill"
        }
    }

    /// 对应的 NSImage（模板图，自动跟随外观配色）。
    var image: NSImage? {
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }
}

/// 统一的弹出式通知封装。
struct AppAlert {
    /// 弹出一个带图标的模态对话框。
    /// - Returns: 用户点击的按钮（`.alertFirstButtonReturn` 即第一个按钮）。
    @discardableResult
    static func show(
        message: String,
        informative: String = "",
        icon: AppAlertIcon = .info,
        style: NSAlert.Style = .informational,
        buttons: [String] = ["确定"]
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = message
        if !informative.isEmpty { alert.informativeText = informative }
        alert.alertStyle = style
        alert.icon = icon.image
        for title in buttons { alert.addButton(withTitle: title) }
        return alert.runModal()
    }
}
