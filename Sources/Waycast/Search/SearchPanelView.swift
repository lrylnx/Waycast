import SwiftUI
import AppKit

/// Gate for hover-selection: only accepts when the physical pointer has
/// actually MOVED since the last hover event. During two-finger scrolling the
/// cursor is stationary while rows slide underneath it; without this gate,
/// onHover keeps re-selecting rows and the highlight jitters.
@MainActor
final class PointerActivity {
    static let shared = PointerActivity()
    private var lastLocation = NSEvent.mouseLocation

    /// Returns true (and records the position) only if the pointer moved.
    func pointerMoved() -> Bool {
        let now = NSEvent.mouseLocation
        let moved = hypot(now.x - lastLocation.x, now.y - lastLocation.y) > 1.5
        lastLocation = now
        return moved
    }
}

/// Layout constants shared with SpotlightController (which resizes the panel
/// to match, keeping the TOP edge anchored so the search box never moves).
enum SearchPanelLayout {
    static let width: CGFloat = 720
    static let barHeight: CGFloat = 64
    static let padding: CGFloat = 12
    /// Height of the visible card (search bar + optional dropdown).
    static func contentHeight(listHeight: CGFloat) -> CGFloat {
        barHeight + (listHeight > 0 ? 1 /*divider*/ + listHeight : 0)
    }
    /// Full panel height (card + outer transparent padding).
    static func panelHeight(listHeight: CGFloat) -> CGFloat {
        contentHeight(listHeight: listHeight) + padding * 2
    }
}

struct SearchPanelView: View {
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            // Dropdown area: grows/shrinks below a FIXED search bar.
            if viewModel.listHeight > 0 {
                Divider().opacity(0.4)
                dropdown
                    .frame(height: viewModel.listHeight)
                    .clipped()
            }
        }
        .frame(width: SearchPanelLayout.width,
               height: SearchPanelLayout.contentHeight(listHeight: viewModel.listHeight),
               alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(SearchPanelLayout.padding)
        .frame(width: SearchPanelLayout.width + SearchPanelLayout.padding * 2,
               height: SearchPanelLayout.panelHeight(listHeight: viewModel.listHeight),
               alignment: .top)
        .onAppear { searchFocused = true }
        .onChange(of: viewModel.focusToken) { _ in searchFocused = true }
        // Esc closes the panel (belt-and-braces alongside the key monitors).
        .onExitCommand { viewModel.onClose?() }
    }

    // MARK: - Search bar (always at the same position)

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.secondary)
            TextField("搜索应用与文件…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .focused($searchFocused)
                .onChange(of: viewModel.query) { _ in viewModel.queryChanged() }
            if viewModel.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: SearchPanelLayout.barHeight)
        // Only the search bar drags the window (native performDrag). The
        // results list stays free for file drags.
        .background(WindowDragArea())
    }

    // MARK: - Dropdown

    @ViewBuilder
    private var dropdown: some View {
        if viewModel.allResults.isEmpty {
            if viewModel.isSearching {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("搜索中…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(maxHeight: .infinity)
            } else {
                emptyState
            }
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if !viewModel.appResults.isEmpty {
                        sectionHeader("应用")
                        ForEach(Array(viewModel.appResults.enumerated()), id: \.element.id) { idx, item in
                            rowView(item, globalIndex: idx)
                        }
                    }
                    if !viewModel.fileResults.isEmpty {
                        if !viewModel.appResults.isEmpty {
                            Divider().padding(.horizontal, 16).padding(.vertical, 6).opacity(0.5)
                        }
                        sectionHeader("文件与文件夹")
                        ForEach(Array(viewModel.fileResults.enumerated()), id: \.element.id) { idx, item in
                            rowView(item, globalIndex: idx + viewModel.appResults.count)
                        }
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)   // trackpad/scroll-wheel is enough
            .onChange(of: viewModel.navToken) { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("row-\(viewModel.selectedIndex)", anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func rowView(_ item: SearchItem, globalIndex: Int) -> some View {
        let selected = viewModel.selectedIndex == globalIndex
        return HStack(spacing: 14) {
            RowIcon(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(item.kind.rawValue)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(selected ? 0.10 : 0.05)))
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(height: 48)
        .background(alignment: .leading) {
            // Soft selection (Finder-sidebar style): translucent accent wash
            // plus a leading accent bar — no heavy solid blue block.
            if selected {
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 9)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 3)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .id("row-\(globalIndex)")
        .onTapGesture { viewModel.select(globalIndex) }
        .onHover { hovering in
            // Only follow the highlight when the pointer itself moved;
            // ignore rows sliding under a stationary cursor while scrolling.
            if hovering, PointerActivity.shared.pointerMoved() {
                viewModel.selectedIndex = globalIndex
            }
        }
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
        .contextMenu {
            Button("打开") { viewModel.open(item) }
            Button("在访达中显示") {
                NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
            }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("无结果")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window drag (search bar only)

/// Invisible backdrop placed behind the search bar; pressing anywhere in the
/// bar that isn't a control starts a native window drag. The results list is
/// NOT covered, so dragging files out of rows works normally.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Row icon with async thumbnail for images/videos

private struct RowIcon: View {
    let item: SearchItem
    @State private var thumbnail: NSImage?

    private var wantsThumbnail: Bool { item.kind == .image || item.kind == .video }

    var body: some View {
        ZStack {
            if wantsThumbnail, let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            } else {
                Image(nsImage: IconCache.shared.icon(forPath: item.url.path))
                    .resizable()
                    .frame(width: 32, height: 32)
            }
            // Play badge on video thumbnails.
            if item.kind == .video, thumbnail != nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(radius: 1)
                    .frame(maxWidth: 32, maxHeight: 32, alignment: .bottomTrailing)
            }
        }
        .onAppear(perform: load)
        .onChange(of: item.id) { _ in thumbnail = nil; load() }
    }

    private func load() {
        guard wantsThumbnail, thumbnail == nil else { return }
        thumbnail = ThumbnailCache.shared.thumbnail(for: item.url, size: 64) { image in
            self.thumbnail = image
        }
    }
}
