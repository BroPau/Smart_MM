//
//  WikiCache.swift
//  Meetinsight
//
//  v2.2.55: WiKi 页面列表缓存——避免每次重启都跑 Python 子进程重建列表。
//  缓存策略：缓存优先 + 后台静默刷新。
//  - 启动时先读缓存秒开列表，后台异步跑 `--list-wiki-pages` 刷新。
//  - 手动「重建 WiKi」/「刷新索引」会立即刷新缓存。
//

import Foundation

/// WiKi 页面列表缓存（单例）。
/// 缓存文件存于 App 私有 caches 目录（`NSCachesDirectory`），不影响用户数据。
final class WikiCache {

    static let shared = WikiCache()

    // MARK: - 缓存信封（Codable）

    private struct CacheEnvelope: Codable {
        let pages: [CachedPage]
        let selectedPageName: String?
        let timestamp: Date
    }

    /// 可序列化的页面快照（与 WikiPage 一一对应）。
    struct CachedPage: Codable {
        let name: String
        let type: String
        let aliases: [String]
        let file: String
        let isHome: Bool

        init(from page: WikiPage) {
            self.name = page.name
            self.type = page.type
            self.aliases = page.aliases
            self.file = page.file
            self.isHome = page.isHome
        }

        func toWikiPage() -> WikiPage {
            WikiPage(name: name, type: type, aliases: aliases, file: file, isHome: isHome)
        }
    }

    // MARK: - 缓存文件路径

    private var cacheURL: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let appCacheDir = cachesDir.appendingPathComponent("Meetinsight", isDirectory: true)
        // 确保目录存在
        try? FileManager.default.createDirectory(at: appCacheDir, withIntermediateDirectories: true)
        return appCacheDir.appendingPathComponent("WikiListCache.json")
    }

    private init() {}

    // MARK: - 读写

    /// 保存页面列表 + 选中页名到缓存。
    func savePages(_ pages: [WikiPage], selectedPageName: String?) {
        let envelope = CacheEnvelope(
            pages: pages.map { CachedPage(from: $0) },
            selectedPageName: selectedPageName,
            timestamp: Date()
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// 读取缓存。返回 (pages, selectedPageName) 或 nil（无缓存 / 解析失败）。
    func loadPages() -> (pages: [WikiPage], selectedPageName: String?)? {
        guard let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else {
            return nil
        }
        let pages = envelope.pages.map { $0.toWikiPage() }
        return (pages, envelope.selectedPageName)
    }

    /// 清除缓存（调试用）。
    func clear() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
