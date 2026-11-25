import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

final class ChatHeightCache {
    static let shared = ChatHeightCache(maxEntries: 4096)

    private struct Key: Hashable {
        let entryId: String
        let width: Int
        let contentHash: Int
        let fontScaleTenths: Int

        init(entryId: String, width: CGFloat, contentHash: Int, fontScaleTenths: Int) {
            self.entryId = entryId
            self.width = Int(width.rounded(.toNearestOrAwayFromZero))
            self.contentHash = contentHash
            self.fontScaleTenths = fontScaleTenths
        }
    }

    private let maxEntries: Int
    private var cache: [Key: CGFloat] = [:]
    private var insertionOrder: [Key] = []
    private let lock = NSLock()

    init(maxEntries: Int = 4096) {
        self.maxEntries = max(1, maxEntries)
    }

    private static func currentFontScaleTenths() -> Int {
        #if canImport(UIKit)
        Int((UIFont.preferredFont(forTextStyle: .body).pointSize * 10).rounded())
        #else
        170
        #endif
    }

    func height(for entry: ChatEntry, width: CGFloat) -> CGFloat? {
        let key = Key(
            entryId: entry.id,
            width: width,
            contentHash: entry.contentHash,
            fontScaleTenths: Self.currentFontScaleTenths()
        )
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    func store(height: CGFloat, for entry: ChatEntry, width: CGFloat) {
        let key = Key(
            entryId: entry.id,
            width: width,
            contentHash: entry.contentHash,
            fontScaleTenths: Self.currentFontScaleTenths()
        )
        lock.lock()
        if cache[key] == nil {
            insertionOrder.append(key)
        }
        cache[key] = height
        while cache.count > maxEntries, !insertionOrder.isEmpty {
            let oldest = insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cache.removeAll()
        insertionOrder.removeAll()
        lock.unlock()
    }
}
