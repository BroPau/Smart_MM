//
//  WikiIndex.swift
//  Meetinsight
//
//  共享的 Wiki 页面索引：缓存 `pipeline.py --list-wiki-pages` 的结果，
//  供「会议纪要」页与「LLM Wiki」页复用，实现「纪要名词 → Wiki 页」联动跳转与自动双链。
//  复用 WikiViewController 中导出的 WikiPage / normalizeForWikiMatch / extractWikiShortName / resolveWikiPage。
//

import Foundation

/// 单例索引：WikiViewController.loadPages() 刷新页面列表时会同步写入此处；
/// MinutesViewController 加载纪要时读取 wikiNames 做名词联动与缺失页判定。
final class WikiIndex {

    static let shared = WikiIndex()

    /// 当前缓存的页面（与 WikiViewController.pages 同源：WikiPage 为 internal struct）。
    private(set) var pages: [WikiPage] = []

    /// 已知页面名（含别名），供编辑器自动双链 / 缺失页判定。
    var wikiNames: [String] { pages.flatMap { [$0.name] + $0.aliases } }

    /// 由 WikiViewController.loadPages 同步写入，无需再次跑子进程。
    func sync(from pages: [WikiPage]) {
        self.pages = pages
    }

    /// 主动刷新（异步调 --list-wiki-pages）。completion 在主线程回调，传入是否成功。
    func refresh(_ completion: ((Bool) -> Void)? = nil) {
        PipelineRunner.shared.run(script: nil, arguments: ["--list-wiki-pages"]) { _ in }
        completion: { [weak self] result in
            guard let self else { completion?(false); return }
            guard result.error == nil,
                  let data = result.stdout.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion?(false)
                return
            }
            var list: [WikiPage] = [
                WikiPage(name: "Wiki 首页", type: "home", aliases: [], file: "Wiki_首页.md", isHome: true)
            ]
            for d in arr {
                guard let name = d["name"] as? String,
                      let type = d["type"] as? String,
                      let file = d["file"] as? String else { continue }
                let aliases = (d["aliases"] as? [String]) ?? []
                list.append(WikiPage(name: name, type: type, aliases: aliases, file: file, isHome: false))
            }
            self.pages = list
            completion?(true)
        }
    }

    /// 按名称/别名解析目标页（5 级匹配，复用 WikiViewController 的 resolveWikiPage）。
    func resolve(rawName: String) -> WikiPage? {
        guard let (_, page) = resolveWikiPage(in: pages, rawName: rawName) else { return nil }
        return page
    }
}
