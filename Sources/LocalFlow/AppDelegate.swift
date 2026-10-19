import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let cleaner = Cleaner()
    private var hotkey: HotkeyMonitor!
    private var isRecording = false
    private var ready = false
    private var targetApp: String?
    private lazy var pill = RecordingPill()

    private enum State { case loading, idle, recording, working, error(String) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let saved = UserDefaults.standard.string(forKey: "hotkey").flatMap(HotkeyMonitor.Key.init(rawValue:))
        hotkey = HotkeyMonitor(key: saved ?? .rightOption)
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.endRecording() }
        set(.loading)
        enableLoginItemOnFirstRun()
        rebuildMenu()

        requestPermissions()
        Task {
            do {
                async let asr: Void = transcriber.load()
                async let llm: Void = cleaner.start()
                _ = try await (asr, llm)
                await MainActor.run {
                    self.ready = true
                    self.set(.idle)
                }
            } catch {
                Log.info("startup failed: \(error.localizedDescription)")
                await MainActor.run { self.set(.error(error.localizedDescription)) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleaner.stop()
    }

    // MARK: Permissions

    private func requestPermissions() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.info("permissions: microphone=\(micStatus.rawValue) (0 undetermined, 2 denied, 3 granted) accessibility=\(AXIsProcessTrusted())")
        if micStatus == .notDetermined {
            // Menu-bar apps aren't frontmost, and macOS may not show the prompt for a background app.
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("permissions: microphone \(granted ? "granted" : "denied")")
                DispatchQueue.main.async { self.rebuildMenu() }
            }
        }
        // Two separate macOS permissions are involved:
        //  - Input Monitoring ("listen events") lets the event tap see the hotkey.
        //  - Accessibility ("post events") lets us send the Cmd+V that pastes the text.
        // These request calls add LocalFlow to the right Settings list and show the system prompt.
        Log.info("permissions: inputMonitoring=\(CGPreflightListenEventAccess()) postEvents=\(CGPreflightPostEventAccess())")
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        if hotkey.start() { return }

        // Keep trying until Input Monitoring is granted. A grant can take effect only after a relaunch,
        // so say so in the menu if it's been a while.
        Log.info("permissions: waiting for Input Monitoring to be granted")
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { return }
            attempts += 1
            if self.hotkey.start() {
                timer.invalidate()
                Log.info("permissions: hotkey ready after \(attempts) checks")
                self.rebuildMenu()
                return
            }
            if attempts % 20 == 0 {
                Log.info("permissions: still waiting (inputMonitoring=\(CGPreflightListenEventAccess()) postEvents=\(CGPreflightPostEventAccess()))")
                self.rebuildMenu()
            }
        }
    }

    // MARK: Login item

    /// Turn on Start at Login once; after that the menu toggle is the user's choice.
    private func enableLoginItemOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        setLoginItem(true)
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("login item: could not \(enabled ? "enable" : "disable"): \(error.localizedDescription)")
        }
        Log.info("login item: status=\(SMAppService.mainApp.status.rawValue) (1 enabled, 2 needs approval, 0/3 off)")
    }

    @objc private func toggleLoginItem() {
        setLoginItem(SMAppService.mainApp.status != .enabled)
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        rebuildMenu()
    }

    // MARK: Dictation flow

    private func beginRecording() {
        guard ready, !isRecording else {
            Log.info("dictation: ignored key press (ready=\(ready), recording=\(isRecording))")
            return
        }
        do {
            targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
            try recorder.start()
            isRecording = true
            Sounds.play("Pop")
            pill.show("● Listening")
            set(.recording)
        } catch {
            Log.info("mic start failed: \(error)")
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        let held = Date().timeIntervalSince(recorder.startedAt)
        let samples = recorder.stop()
        guard held >= Config.minHoldSeconds else {
            Log.info("dictation: key held only \(Int(held * 1000)) ms, ignoring")
            pill.hide()
            set(.idle)
            return
        }
        Sounds.play("Bottle")
        pill.show("Writing…")
        set(.working)
        let released = Date()
        let app = targetApp
        Task {
            defer { Task { @MainActor in self.pill.hide(); self.set(.idle) } }
            do {
                let raw = try await transcriber.transcribe(samples)
                let asrMs = ms(since: released)
                guard !raw.isEmpty else {
                    Log.info("dictation: no speech recognized in \(samples.count / 16) ms of audio")
                    return
                }
                let (text, path) = await cleaner.clean(raw, app: app)
                let totalMs = ms(since: released)
                Log.info("dictation: app=\(app ?? "?") audio=\(samples.count / 16)ms asr=\(asrMs)ms total=\(totalMs)ms path=\(path)")
                await MainActor.run { Paster.insert(text) }
            } catch {
                Log.info("dictation failed: \(error)")
            }
        }
    }

    // MARK: Menu bar

    private func set(_ state: State) {
        let symbol: String
        let tooltip: String
        switch state {
        case .loading: symbol = "hourglass"; tooltip = "LocalFlow: loading models…"
        case .idle: symbol = "mic"; tooltip = "LocalFlow: hold \(hotkey.key.rawValue) to dictate"
        case .recording: symbol = "mic.fill"; tooltip = "LocalFlow: listening"
        case .working: symbol = "ellipsis.circle"; tooltip = "LocalFlow: transcribing"
        case .error(let message): symbol = "exclamationmark.triangle"; tooltip = "LocalFlow: \(message)"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        if case .recording = state {
            statusItem.button?.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        } else {
            image?.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = tooltip
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let missing = [
            (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Microphone", "Privacy_Microphone"),
            (hotkey.isActive, "Input Monitoring", "Privacy_ListenEvent"),
            (CGPreflightPostEventAccess(), "Accessibility", "Privacy_Accessibility"),
        ].filter { !$0.0 }
        let status = missing.isEmpty ? "Hold \(hotkey.key.rawValue) to dictate" : "Needs permissions to work:"
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        for (_, name, anchor) in missing {
            let item = NSMenuItem(title: "  Turn on \(name)…", action: #selector(openSettings(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = anchor
            menu.addItem(item)
        }
        if !missing.isEmpty {
            let restart = NSMenuItem(title: "  Restart LocalFlow (after granting)", action: #selector(restartApp), keyEquivalent: "")
            restart.target = self
            menu.addItem(restart)
        }
        menu.addItem(.separator())

        let keyMenu = NSMenu()
        for key in HotkeyMonitor.Key.allCases {
            let item = NSMenuItem(title: key.rawValue, action: #selector(chooseKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = key == hotkey.key ? .on : .off
            keyMenu.addItem(item)
        }
        let keyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let dict = NSMenuItem(title: "Edit Dictionary…", action: #selector(openDictionary), keyEquivalent: "")
        dict.target = self
        menu.addItem(dict)
        let log = NSMenuItem(title: "Show Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func chooseKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = HotkeyMonitor.Key(rawValue: raw) else { return }
        hotkey.key = key
        UserDefaults.standard.set(raw, forKey: "hotkey")
        rebuildMenu()
        set(ready ? .idle : .loading)
    }

    @objc private func openDictionary() {
        let url = Config.dictionaryFile
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = "# One word or name per line, spelled the way you want it typed.\n# Example:\nWix\nBase44\n"
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        guard let anchor = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    @objc private func restartApp() {
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Config.logFile)
    }
}

enum AudioFile {
    /// Reads any audio file AVFoundation understands and returns 16 kHz mono samples.
    static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
