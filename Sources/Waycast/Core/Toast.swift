import Cocoa

/// A transient toast shown near the bottom of the screen.
enum Toast {
    private static var current: NSWindow?

    @MainActor
    static func show(_ text: String, duration: TimeInterval = 1.6) {
        current?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()

        let padding: CGFloat = 14
        let size = NSSize(width: label.frame.width + padding * 2,
                          height: label.frame.height + padding)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        container.layer?.cornerRadius = size.height / 2
        label.frame.origin = NSPoint(x: padding, y: (size.height - label.frame.height) / 2)
        container.addSubview(label)
        window.contentView = container

        if let screen = ScreenUtils.screenContainingMouse() {
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.minY + 80
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }

        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
        current = window

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak window] in
            guard let window else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
                if Toast.current === window { Toast.current = nil }
            })
        }
    }
}
