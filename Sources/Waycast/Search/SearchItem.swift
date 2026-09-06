import Cocoa
import QuickLookThumbnailing

/// One searchable result: an application, a file, a folder, image or video.
struct SearchItem: Identifiable, Hashable {
    enum Kind: String {
        case app = "应用"
        case file = "文件"
        case folder = "文件夹"
        case image = "图片"
        case video = "视频"
    }

    let id: String          // file path (unique)
    let kind: Kind
    let title: String
    /// Secondary name to match against (e.g. the English bundle name of an
    /// app whose title is localized: title="磁盘工具", altName="Disk Utility").
    let altName: String?
    let subtitle: String    // directory path
    let url: URL

    init(id: String, kind: Kind, title: String, altName: String? = nil,
         subtitle: String, url: URL) {
        self.id = id
        self.kind = kind
        self.title = title
        self.altName = altName
        self.subtitle = subtitle
        self.url = url
    }

    static func == (lhs: SearchItem, rhs: SearchItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Small thread-safe icon cache so repeated searches don't re-render icons.
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 2000
    }

    func icon(forPath path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

/// Async QuickLook thumbnails for images/videos, keyed by path.
/// Falls back to the file icon when generation fails.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let generator = QLThumbnailGenerator.shared
    private var inFlight = Set<String>()
    private let lock = NSLock()

    init() { cache.countLimit = 400 }

    /// Returns the cached thumbnail if present, else starts generation and
    /// calls `onReady` on the main thread when done.
    func thumbnail(for url: URL, size: CGFloat, onReady: @escaping (NSImage) -> Void) -> NSImage? {
        let key = url.path
        if let hit = cache.object(forKey: key as NSString) { return hit }

        lock.lock()
        let already = inFlight.contains(key)
        if !already { inFlight.insert(key) }
        lock.unlock()
        guard !already else { return nil }

        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: size, height: size),
                                                   scale: 2,
                                                   representationTypes: .thumbnail)
        generator.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let self else { return }
            self.lock.lock()
            self.inFlight.remove(key)
            self.lock.unlock()
            var image: NSImage
            if let rep {
                image = NSImage(cgImage: rep.cgImage, size: NSSize(width: size, height: size))
            } else {
                image = NSWorkspace.shared.icon(forFile: key)
                image.size = NSSize(width: size, height: size)
            }
            self.cache.setObject(image, forKey: key as NSString)
            DispatchQueue.main.async { onReady(image) }
        }
        return nil
    }
}
