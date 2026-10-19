import AppKit

enum Sounds {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true
    }

    static func play(_ name: String) {
        guard enabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// A small floating pill at the bottom of the screen while the mic is on.
/// It ignores clicks, never takes focus, and shows on every Space and over full-screen apps.
final class RecordingPill {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private static let size = NSSize(width: 150, height: 34)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.size.height / 2
        content.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.85).cgColor
        label.frame = NSRect(x: 0, y: (Self.size.height - 18) / 2, width: Self.size.width, height: 18)
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        content.addSubview(label)
        panel.contentView = content
    }

    func show(_ text: String) {
        label.stringValue = text
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - Self.size.width / 2, y: screen.minY + 24))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
