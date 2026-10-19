import AppKit
import ApplicationServices
import AVFoundation

// Command-line test modes (no hotkey, no paste):
//   LocalFlow --test-audio file.wav   transcribe + clean a file, print timings
//   LocalFlow --test-text "um hi"     clean text only
let args = CommandLine.arguments
//   LocalFlow --eval cases.jsonl [results.jsonl]   grade the cleanup pipeline against a test set
if args.count >= 3, args[1] == "--eval" {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do { try await Eval.run(casesFile: args[2], outFile: args.count >= 4 ? args[3] : nil) }
        catch { print("error: \(error)") }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}
if args.count >= 3, args[1] == "--test-audio" || args[1] == "--test-text" {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let cleaner = Cleaner()
        do {
            try await cleaner.start()
            let transcriber = Transcriber()
            if args[1] == "--test-audio" { try await transcriber.load() }
            for input in args.dropFirst(2) {
                var raw = input
                if args[1] == "--test-audio" {
                    let samples = try AudioFile.load16kMono(URL(fileURLWithPath: input))
                    let t0 = Date()
                    raw = try await transcriber.transcribe(samples)
                    print("ASR   (\(ms(since: t0)) ms, \(samples.count / 16) ms audio): \(raw)")
                }
                let t1 = Date()
                let (text, path) = await cleaner.clean(raw)
                print("CLEAN (\(ms(since: t1)) ms, \(path)): \(text)\n")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
        cleaner.stop()
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
