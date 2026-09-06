import SwiftUI
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var appResults: [SearchItem] = []
    @Published var fileResults: [SearchItem] = []
    @Published var selectedIndex: Int = 0
    @Published var isSearching: Bool = false
    /// Incremented on every show so the SwiftUI view re-focuses the text field.
    @Published var focusToken: Int = 0
    /// Incremented only on KEYBOARD navigation. The list auto-scrolls to keep
    /// this in view; hover-selection does NOT bump it, otherwise two-finger
    /// scrolling would fight the scrollTo and the highlight would jitter.
    @Published var navToken: Int = 0
    /// Height of the dropdown results area (0 = collapsed, search bar only).
    /// The panel keeps its TOP edge fixed and grows downward — the search box
    /// never moves.
    @Published var listHeight: CGFloat = 0

    var onClose: (() -> Void)?

    private var debounceTask: Task<Void, Never>?

    var allResults: [SearchItem] { appResults + fileResults }

    func reset() {
        query = ""
        appResults = []
        fileResults = []
        selectedIndex = 0
        isSearching = false
        debounceTask?.cancel()
        focusToken += 1
        updateListHeight()
    }

    func queryChanged() {
        debounceTask?.cancel()
        let text = query
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            appResults = []
            fileResults = []
            selectedIndex = 0
            isSearching = false
            updateListHeight()
            return
        }
        isSearching = true
        updateListHeight()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000) // 60ms debounce
            guard !Task.isCancelled, let self else { return }
            SearchEngine.shared.search(text: text) { [weak self] apps in
                guard let self, self.query == text else { return }
                self.appResults = apps
                self.clampSelection()
                self.updateListHeight()
            } onFiles: { [weak self] files in
                guard let self, self.query == text else { return }
                self.fileResults = files
                self.isSearching = false
                self.clampSelection()
                self.updateListHeight()
            }
        }
    }

    /// rows ≈ 52pt (48 + 4 spacing), section headers ≈ 30pt,
    /// divider + margins ≈ 25pt.
    private func updateListHeight() {
        let rows = appResults.count + fileResults.count
        if rows > 0 {
            var h: CGFloat = 25
            if !appResults.isEmpty { h += 30 }
            if !fileResults.isEmpty { h += 30 }
            if !appResults.isEmpty && !fileResults.isEmpty { h += 13 }
            h += CGFloat(rows) * 52
            listHeight = min(h, 460)
        } else if isSearching {
            listHeight = 52
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            listHeight = 96
        } else {
            listHeight = 0
        }
    }

    func moveSelection(by delta: Int) {
        let count = allResults.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
        navToken += 1
    }

    func select(_ index: Int) {
        guard allResults.indices.contains(index) else { return }
        selectedIndex = index
        activateSelection()
    }

    func activateSelection() {
        let items = allResults
        guard items.indices.contains(selectedIndex) else { return }
        open(items[selectedIndex])
    }

    func open(_ item: SearchItem) {
        switch item.kind {
        case .app:
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: item.url, configuration: config)
        case .file, .folder, .image, .video:
            NSWorkspace.shared.open(item.url)
        }
        onClose?()
    }

    private func clampSelection() {
        let count = allResults.count
        if count == 0 { selectedIndex = 0 }
        else { selectedIndex = min(selectedIndex, count - 1) }
    }
}
