import Cocoa
import CoreServices
import os

/// Search engine combining a local application index (instant) with
/// Spotlight (MDQuery) for files and folders (async).
final class SearchEngine {
    static let shared = SearchEngine()

    private var appIndex: [SearchItem] = []
    /// Dedicated serial queue that Spotlight uses to deliver results.
    private let spotlightQueue = DispatchQueue(label: "waycast.spotlight.results", qos: .userInitiated)

    // Generation + current query are touched from both main and spotlightQueue.
    private let lock = NSLock()
    private var _queryGeneration = 0
    private var _currentQuery: MDQuery?

    private func bumpGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        _queryGeneration += 1
        return _queryGeneration
    }
    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _queryGeneration == generation
    }
    private func setCurrent(_ md: MDQuery?) -> MDQuery? {
        lock.lock(); defer { lock.unlock() }
        let old = _currentQuery
        _currentQuery = md
        return old
    }
    private func clearCurrentIf(_ md: MDQuery) {
        lock.lock(); defer { lock.unlock() }
        if _currentQuery === md { _currentQuery = nil }
    }

    // MARK: - App index

    func warmUp() {
        rebuildAppIndex()
    }

    func rebuildAppIndex() {
        var items: [SearchItem] = []
        var seen = Set<String>()
        let fm = FileManager.default
        let dirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = dir + "/" + entry
                let id = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard seen.insert(id).inserted else { continue }
                let enName = (entry as NSString).deletingPathExtension
                // Localized display name (e.g. "磁盘工具" for Disk Utility.app).
                // Only Spotlight/LSCopy expose it; FileManager.localizedName
                // and Bundle return the English name.
                var displayName = enName
                if let md = MDItemCreate(kCFAllocatorDefault, path as CFString),
                   let dn = MDItemCopyAttribute(md, kMDItemDisplayName) as? String,
                   !dn.isEmpty {
                    displayName = (dn as NSString).deletingPathExtension
                }
                items.append(SearchItem(id: id, kind: .app, title: displayName,
                                        altName: displayName == enName ? nil : enName,
                                        subtitle: dir,
                                        url: URL(fileURLWithPath: path)))
            }
        }
        appIndex = items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Search entry point (call on main thread)

    func search(text: String,
                onApps: @escaping ([SearchItem]) -> Void,
                onFiles: @escaping ([SearchItem]) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onApps([]); onFiles([]); return
        }
        onApps(rankApps(query: trimmed))

        let generation = bumpGeneration()
        let predicate = Self.buildQueryString(trimmed)

        // Stop any in-flight query before starting a new one.
        if let previous = setCurrent(nil) { MDQueryStop(previous) }

        // Run Spotlight SYNCHRONOUSLY on the background queue with NO dispatch
        // queue attached. That guarantees the result list cannot be mutated
        // while we iterate it, so the MDItem pointers returned by
        // MDQueryGetResultAtIndex stay valid for the whole read. Attaching a
        // dispatch queue (the old async mode) let Spotlight purge results
        // mid-iteration — the dangling MDItem was the objc_release SIGSEGV.
        spotlightQueue.async { [weak self] in
            guard let self else { return }
            guard let md = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) else { return }
            _ = self.setCurrent(md)
            // kMDQuerySyncExecution = 1: blocks this queue until gathering is
            // done; MDQueryStop() from another thread aborts it early.
            _ = MDQueryExecute(md, CFOptionFlags(1))
            let items = self.collect(md, limit: 40)
            self.clearCurrentIf(md)
            DispatchQueue.main.async {
                if self.isCurrent(generation) { onFiles(items) }
            }
        }
    }

    // MARK: - App ranking (fuzzy)

    private func rankApps(query: String) -> [SearchItem] {
        let q = query.lowercased()
        let tokens = q.split(separator: " ").map(String.init)
        var scored: [(Int, SearchItem)] = []
        for item in appIndex {
            // Match against BOTH the localized title (磁盘工具) and the
            // English alt name (Disk Utility); keep the better score.
            var best = 0
            for name0 in [item.title, item.altName ?? ""] where !name0.isEmpty {
                let name = name0.lowercased()
                let stem = name.replacingOccurrences(of: " ", with: "")
                var score = 0
                if name == q { score = 1000 }
                else if name.hasPrefix(q) { score = 800 }
                else if stem.hasPrefix(q) { score = 700 }
                else if name.contains(q) { score = 500 }
                else if !tokens.isEmpty, tokens.allSatisfy({ name.contains($0) }) { score = 300 }
                else if isSubsequence(q.replacingOccurrences(of: " ", with: ""), in: stem) { score = 100 }
                best = max(best, score)
            }
            var score = best
            if score > 0 {
                if item.subtitle.hasPrefix("/System") { score -= 40 }
                scored.append((score, item))
            }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(20).map(\.1)
    }

    private func isSubsequence(_ sub: String, in str: String) -> Bool {
        guard !sub.isEmpty else { return false }
        var idx = str.startIndex
        for ch in sub {
            guard let found = str[idx...].firstIndex(of: ch) else { return false }
            idx = str.index(after: found)
        }
        return true
    }

    // MARK: - Spotlight helpers

    /// Read results from a SYNCHRONOUSLY executed query. Safe because no
    /// dispatch queue is attached, so nothing mutates the result list while
    /// we iterate. Extract plain strings immediately and never let the MDItem
    /// references escape this function.
    private func collect(_ md: MDQuery, limit: Int) -> [SearchItem] {
        let count = MDQueryGetResultCount(md)
        var items: [SearchItem] = []
        items.reserveCapacity(min(Int(count), limit))
        for i in 0..<min(count, CFIndex(limit)) {
            guard let raw = MDQueryGetResultAtIndex(md, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let name = (path as NSString).lastPathComponent
            var kind: SearchItem.Kind = isDir.boolValue ? .folder : .file
            if !isDir.boolValue {
                let tree = (MDItemCopyAttribute(item, kMDItemContentTypeTree) as? [String]) ?? []
                if tree.contains(where: { $0.hasPrefix("public.image") }) {
                    kind = .image
                } else if tree.contains(where: { $0.hasPrefix("public.movie") || $0.hasPrefix("public.video") }) {
                    kind = .video
                }
            }
            items.append(SearchItem(id: path, kind: kind, title: name,
                                    subtitle: dirAbbrev((path as NSString).deletingLastPathComponent),
                                    url: URL(fileURLWithPath: path)))
        }
        return items
    }

    private func dirAbbrev(_ dir: String) -> String {
        let home = NSHomeDirectory()
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") { return "~" + dir.dropFirst(home.count) }
        return dir
    }

    static func buildQueryString(_ raw: String) -> String {
        let tokens = raw.split(separator: " ").map(String.init)
        let clauses = tokens.map { token -> String in
            let escaped = token
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "?", with: "")
            return "(kMDItemDisplayName == '*\(escaped)*'c || kMDItemFSName == '*\(escaped)*'c)"
        }
        let namePart = clauses.joined(separator: " && ")
        return "\(namePart) && kMDItemContentTypeTree != 'com.apple.application-bundle'cd"
    }
}
