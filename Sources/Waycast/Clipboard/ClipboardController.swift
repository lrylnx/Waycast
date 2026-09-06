import Cocoa

/// Polls the general pasteboard and keeps a history of text entries only.
/// Exposes an NSMenu for the status bar. History is persisted to disk so it
/// survives quit / crash relaunches.
final class ClipboardController: NSObject, NSMenuDelegate {
    struct Entry: Codable {
        let text: String
        let date: Date
    }

    private(set) var entries: [Entry] = []
    let menu = NSMenu()

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Waycast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard_history.json")
    }()

    func start() {
        load()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuildMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        let limit = AppSettings.shared.clipboardLimit
        entries = Array(saved.prefix(limit))
    }

    private func save() {
        // Atomic write; happens on every history mutation (a few per minute
        // at most, tiny payload — no need to debounce).
        do {
            let data = try JSONEncoder().encode(entries)
            let tmp = storeURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmp)
        } catch {
            NSLog("Waycast clipboard save failed: %@", "\(error)")
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string) else { return }
        NSLog("Waycast clipboard captured %d chars", text.count)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // De-duplicate: move existing entry to top.
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, date: Date()), at: 0)
        let limit = AppSettings.shared.clipboardLimit
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        save()
        rebuildMenu()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        if entries.isEmpty {
            let item = NSMenuItem(title: "暂无剪贴板记录", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        for (idx, entry) in entries.enumerated() {
            let preview = Self.preview(entry.text)
            let item = NSMenuItem(title: preview, action: #selector(pasteEntry(_:)), keyEquivalent: "")
            item.target = self
            item.tag = idx
            item.toolTip = entry.text
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "清空历史记录", action: #selector(clearAll), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func pasteEntry(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag) else { return }
        let text = entries[sender.tag].text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Move to top.
        entries.remove(at: sender.tag)
        entries.insert(Entry(text: text, date: Date()), at: 0)
        save()
        rebuildMenu()
    }

    @objc private func clearAll() {
        entries.removeAll()
        save()
        rebuildMenu()
    }

    static func preview(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\t", with: " ")
        if oneLine.count <= 60 { return oneLine }
        return String(oneLine.prefix(60)) + "…"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Refresh in case limit changed.
        rebuildMenu()
    }
}
