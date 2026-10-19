import Foundation

/// File locations and tunables. Everything lives under ~/Library/Application Support/LocalFlow.
enum Config {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var llamaServer: URL { supportDir.appendingPathComponent("llama/llama-server") }
    /// The cleanup model. Override with LOCALFLOW_MODEL (a file name in models/ or a full path),
    /// or `defaults write local.localflow model <name>`.
    static var modelFile: URL {
        let name = ProcessInfo.processInfo.environment["LOCALFLOW_MODEL"]
            ?? UserDefaults.standard.string(forKey: "model")
            ?? "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        return name.hasPrefix("/") ? URL(fileURLWithPath: name) : supportDir.appendingPathComponent("models/\(name)")
    }
    static var dictionaryFile: URL { supportDir.appendingPathComponent("dictionary.txt") }
    static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LocalFlow.log")
    }

    /// Override with LOCALFLOW_PORT, e.g. to evaluate another model while the app is running.
    static let llmPort = Int(ProcessInfo.processInfo.environment["LOCALFLOW_PORT"] ?? "") ?? 8178
    /// Recordings shorter than this are treated as accidental taps and ignored.
    static let minHoldSeconds = 0.3
    /// If the LLM takes longer than this, paste the rule-based cleanup instead.
    static let llmTimeoutSeconds = 4.0

    /// Words and names you want spelled a particular way, one per line.
    static func dictionaryTerms() -> [String] {
        guard let text = try? String(contentsOf: dictionaryFile, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "localflow.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        queue.async {
            let url = Config.logFile
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}
