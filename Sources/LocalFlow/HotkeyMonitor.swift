import AppKit
import CoreGraphics

/// Watches a single modifier key system-wide and reports press / release.
/// Uses a listen-only CGEventTap on flagsChanged, which needs the Input Monitoring permission.
final class HotkeyMonitor {
    enum Key: String, CaseIterable {
        case rightOption = "Right Option"
        case fn = "Fn (Globe)"
        case rightCommand = "Right Command"

        var keyCode: Int64 {
            switch self {
            case .rightOption: return 61
            case .fn: return 63
            case .rightCommand: return 54
            }
        }

        var flag: CGEventFlags {
            switch self {
            case .rightOption: return .maskAlternate
            case .fn: return .maskSecondaryFn
            case .rightCommand: return .maskCommand
            }
        }
    }

    var key: Key
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var tap: CFMachPort?
    private var isDown = false
    private var watchdog: Timer?

    init(key: Key) { self.key = key }

    var isActive: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        Log.info("hotkey: event tap active, listening for \(key.rawValue)")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps that are slow or interrupted; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.info("hotkey: tap was disabled by macOS (\(type.rawValue)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == key.keyCode else { return }

        let pressed = event.flags.contains(key.flag)
        if pressed && !isDown {
            isDown = true
            Log.info("hotkey: pressed")
            onPress?()
        } else if !pressed && isDown {
            release(reason: "released")
        }
    }

    private func release(reason: String) {
        isDown = false
        Log.info("hotkey: \(reason)")
        onRelease?()
    }

    /// If macOS drops the key-up event (it can disable the tap under load), the mic would stay on.
    /// Poll the physical key state while the key is held and stop if it's actually up.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.isDown else { return }
            if !CGEventSource.flagsState(.hidSystemState).contains(self.key.flag) {
                self.release(reason: "release missed; watchdog stopped recording")
            }
        }
    }
}
