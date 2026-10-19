import Foundation

/// Runs every case in a JSONL test set through the real cleanup pipeline (fast path, LLM, sanity checks,
/// fallbacks) and grades the output.
///
/// Each line: {"id", "cat", "raw", "expected", "app"?, "must"?: [..], "must_not"?: [..], "min_sim"?: 0.0-1.0}
/// A case passes when every `must` phrase appears, no `must_not` phrase appears (case-insensitive,
/// whole words), and word-level similarity to `expected` is at least `min_sim` (default 0.75).
enum Eval {
    struct Case: Decodable {
        let id: String
        let cat: String
        let raw: String
        let expected: String
        let app: String?
        let must: [String]?
        let must_not: [String]?
        let min_sim: Double?
    }

    struct Result: Encodable {
        let id: String
        let cat: String
        let pass: Bool
        let sim: Double
        let ms: Int
        let path: String
        let output: String
        let problems: [String]
    }

    static func run(casesFile: String, outFile: String?) async throws {
        let lines = try String(contentsOfFile: casesFile, encoding: .utf8).split(whereSeparator: \.isNewline)
        let cases = try lines.filter { !$0.hasPrefix("//") }.map {
            try JSONDecoder().decode(Case.self, from: Data($0.utf8))
        }
        let cleaner = Cleaner()
        try await cleaner.start()
        defer { cleaner.stop() }

        var results: [Result] = []
        for c in cases {
            let t0 = Date()
            let (output, path) = await cleaner.clean(c.raw, app: c.app ?? "Notes")
            let elapsed = ms(since: t0)
            var problems: [String] = []
            for phrase in c.must ?? [] where !contains(output, phrase) { problems.append("missing \"\(phrase)\"") }
            for phrase in c.must_not ?? [] where contains(output, phrase) { problems.append("has \"\(phrase)\"") }
            let sim = similarity(output, c.expected)
            if sim < (c.min_sim ?? 0.75) { problems.append(String(format: "similarity %.2f", sim)) }
            results.append(Result(id: c.id, cat: c.cat, pass: problems.isEmpty, sim: sim, ms: elapsed,
                                  path: path, output: output, problems: problems))
        }

        // Failures first, with enough context to see what went wrong.
        for (c, r) in zip(cases, results) where !r.pass {
            print("FAIL \(r.id) [\(r.cat)] \(r.path) \(r.ms)ms — \(r.problems.joined(separator: "; "))")
            print("  raw: \(c.raw)")
            print("  got: \(r.output.replacingOccurrences(of: "\n", with: "⏎"))")
            print("  exp: \(c.expected.replacingOccurrences(of: "\n", with: "⏎"))\n")
        }

        print("By category:")
        for cat in Set(results.map(\.cat)).sorted() {
            let group = results.filter { $0.cat == cat }
            print(String(format: "  %-14@ %2d/%-2d  avg sim %.2f", cat as NSString,
                         group.filter(\.pass).count, group.count, group.map(\.sim).reduce(0, +) / Double(group.count)))
        }
        let passed = results.filter(\.pass).count
        let times = results.map(\.ms).sorted()
        let llmTimes = results.filter { $0.path == "llm" }.map(\.ms).sorted()
        func pct(_ xs: [Int], _ p: Double) -> Int { xs.isEmpty ? 0 : xs[min(xs.count - 1, Int(Double(xs.count) * p))] }
        let paths = Dictionary(grouping: results, by: \.path).mapValues(\.count)
        print("\nmodel: \(Config.modelFile.lastPathComponent)")
        print(String(format: "TOTAL %d/%d passed (%.0f%%)", passed, results.count, 100 * Double(passed) / Double(results.count)))
        print("latency all: p50 \(pct(times, 0.5)) ms, p95 \(pct(times, 0.95)) ms | llm only: p50 \(pct(llmTimes, 0.5)) ms, p95 \(pct(llmTimes, 0.95)) ms")
        print("paths: \(paths.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

        if let outFile {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let body = try results.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
            try body.write(toFile: outFile, atomically: true, encoding: .utf8)
        }
    }

    /// Whole-word, case-insensitive phrase match ("um" doesn't match "umbrella").
    static func contains(_ text: String, _ phrase: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let start = phrase.first.map { $0.isLetter || $0.isNumber } == true ? #"\b"# : ""
        let end = phrase.last.map { $0.isLetter || $0.isNumber } == true ? #"\b"# : ""
        return text.range(of: start + escaped + end, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 1 - (word-level edit distance / longer length), ignoring case and punctuation.
    static func similarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'$%")))
                .filter { !$0.isEmpty }
        }
        let x = words(a), y = words(b)
        if x.isEmpty && y.isEmpty { return 1 }
        var prev = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        let distance = x.isEmpty ? y.count : prev[y.count]
        return 1 - Double(distance) / Double(max(x.count, y.count))
    }
}
