import Cocoa
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import ScreenCaptureKit

enum ScreenCapture {
    /// Capture one display's pixels (top-left origin). Completion on main thread.
    static func capture(screen: NSScreen, completion: @escaping (CGImage?) -> Void) {
        if #available(macOS 14.0, *) {
            captureWithSCK(screen: screen) { img in
                DispatchQueue.main.async { completion(img) }
            }
        } else {
            let img = CGDisplayCreateImage(screen.displayID)
            DispatchQueue.main.async { completion(img) }
        }
    }

    @available(macOS 14.0, *)
    private static func captureWithSCK(screen: NSScreen, completion: @escaping (CGImage?) -> Void) {
        let scale = screen.backingScaleFactor
        let targetID = screen.displayID
        SCShareableContent.getWithCompletionHandler { content, _ in
            guard let display = content?.displays.first(where: { $0.displayID == targetID }) else {
                completion(nil); return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            if #available(macOS 15.0, *) { config.captureResolution = .best }
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { img, _ in
                completion(img)
            }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }
}

// MARK: - Image processing

enum ImageProcessor {
    /// Pixelate by downscale + nearest-neighbour upscale.
    static func pixelate(_ image: CGImage, blockSize: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        let smallW = max(1, Int(CGFloat(w) / max(2, blockSize)))
        let smallH = max(1, Int(CGFloat(h) / max(2, blockSize)))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let smallCtx = CGContext(data: nil, width: smallW, height: smallH,
                                       bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        smallCtx.interpolationQuality = .none
        smallCtx.draw(image, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let small = smallCtx.makeImage() else { return nil }
        guard let outCtx = CGContext(data: nil, width: w, height: h,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        outCtx.interpolationQuality = .none
        outCtx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
        return outCtx.makeImage()
    }

    /// OCR (Chinese + English). Completion on main thread.
    static func recognizeText(in image: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Filter against the languages this OS actually supports:
            // assigning an unsupported one makes perform(_:) throw, which
            // previously surfaced as "OCR does nothing".
            var langs = ["zh-Hans", "zh-Hant", "en-US"]
            if let supported = try? request.supportedRecognitionLanguages() {
                let filtered = langs.filter { supported.contains($0) }
                langs = filtered.isEmpty ? Array(supported.prefix(2)) : filtered
            }
            request.recognitionLanguages = langs
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do {
                try handler.perform([request])
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                DispatchQueue.main.async { completion(text) }
            } catch {
                NSLog("Waycast OCR failed: \(error)")
                DispatchQueue.main.async { completion("") }
            }
        }
    }

    /// Crop in pixel coords (row 0 = top).
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(bounds)
        guard !r.isEmpty else { return nil }
        return image.cropping(to: r)
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func saveWithPanel(_ image: CGImage, defaultName: String) {
        guard let data = pngData(image) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultName
        // Default to the Desktop (fall back to Downloads if unavailable).
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory,
                                                      in: .userDomainMask).first
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    static func copyToPasteboard(_ image: CGImage) {
        guard let data = pngData(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
    }
}
