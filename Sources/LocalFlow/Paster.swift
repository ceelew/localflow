import AppKit
import Carbon
import CoreGraphics

/// Inserts text at the cursor of the frontmost app by pasting, then restores the old clipboard.
enum Paster {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        // A password field has focus: macOS blocks synthetic keystrokes there, and dictation
        // shouldn't land on the clipboard either.
        if IsSecureEventInputEnabled() {
            Log.info("paste: secure input field focused; not pasting")
            Sounds.play("Basso")
            return
        }
        if !CGPreflightPostEventAccess() {
            Log.info("paste: Accessibility not granted, so Cmd+V can't be sent")
        }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendCommandV()

        // Give the target app time to read the clipboard before putting the old contents back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pasteboard.clearContents()
            let items = saved.map { entry -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    private static func sendCommandV() {
        // Send a full Cmd-down, V-down, V-up, Cmd-up sequence; some apps ignore a bare flagged V.
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdKey: CGKeyCode = 55, vKey: CGKeyCode = 9
        let events = [
            CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
            CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false),
        ]
        events[1]?.flags = .maskCommand
        events[2]?.flags = .maskCommand
        for event in events { event?.post(tap: .cghidEventTap) }
    }
}
