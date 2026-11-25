import Foundation
import MarkdownParser
import MarkdownView

final class ChatMarkdownPackageCache {
    static let shared = ChatMarkdownPackageCache(maxEntries: 192)

    private struct CacheEntry {
        let contentHash: Int
        let themeIdentity: Int
        let preprocessPathLinks: Bool
        let package: MarkdownTextView.PreprocessedContent
    }

    private let maxEntries: Int
    private var cache: [String: CacheEntry] = [:]
    private var recencyOrder: [String] = []
    private let lock = NSLock()

    init(maxEntries: Int = 192) {
        self.maxEntries = max(1, maxEntries)
    }

    static func themeIdentity(for theme: MarkdownTheme) -> Int {
        String(describing: theme).hashValue
    }

    func package(
        for entryID: String,
        content: String,
        theme: MarkdownTheme,
        themeIdentity: Int? = nil,
        preprocessPathLinks: Bool = false
    ) -> MarkdownTextView.PreprocessedContent {
        let contentHash = content.hashValue
        let resolvedThemeIdentity = themeIdentity ?? Self.themeIdentity(for: theme)
        let cacheKey = preprocessPathLinks ? "\(entryID)#pathLinks" : entryID

        lock.lock()
        if let cached = cache[cacheKey],
           cached.contentHash == contentHash,
           cached.themeIdentity == resolvedThemeIdentity,
           cached.preprocessPathLinks == preprocessPathLinks
        {
            touchLocked(cacheKey)
            lock.unlock()
            return cached.package
        }
        lock.unlock()

        return updateCache(
            cacheKey: cacheKey,
            content: content,
            contentHash: contentHash,
            theme: theme,
            themeIdentity: resolvedThemeIdentity,
            preprocessPathLinks: preprocessPathLinks
        )
    }

    func removeAll() {
        lock.lock()
        cache.removeAll()
        recencyOrder.removeAll()
        lock.unlock()
    }

    private func updateCache(
        cacheKey: String,
        content: String,
        contentHash: Int,
        theme: MarkdownTheme,
        themeIdentity: Int,
        preprocessPathLinks: Bool
    ) -> MarkdownTextView.PreprocessedContent {
        let effectiveContent = preprocessPathLinks ? ChatPathLinkPreprocessor.preprocess(content) : content
        let parserResult = MarkdownParser().parse(effectiveContent)
        let package = MarkdownTextView.PreprocessedContent(parserResult: parserResult, theme: theme)

        lock.lock()
        cache[cacheKey] = CacheEntry(
            contentHash: contentHash,
            themeIdentity: themeIdentity,
            preprocessPathLinks: preprocessPathLinks,
            package: package
        )
        touchLocked(cacheKey)
        while cache.count > maxEntries, let evicted = recencyOrder.first {
            recencyOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        lock.unlock()

        return package
    }

    private func touchLocked(_ entryID: String) {
        if recencyOrder.last == entryID { return }
        if let existingIndex = recencyOrder.firstIndex(of: entryID) {
            recencyOrder.remove(at: existingIndex)
        }
        recencyOrder.append(entryID)
    }
}
