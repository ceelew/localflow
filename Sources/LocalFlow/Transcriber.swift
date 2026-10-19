import FluidAudio
import Foundation

/// Speech-to-text with NVIDIA Parakeet TDT 0.6B v3, running on the Apple Neural Engine via FluidAudio.
/// The model (~600 MB) is downloaded from Hugging Face on first use and cached locally; after that it runs offline.
actor Transcriber {
    private var manager: AsrManager?
    private var decoderLayers = 2

    func load() async throws {
        guard manager == nil else { return }
        let started = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
        decoderLayers = models.version.decoderLayers
        Log.info("asr: Parakeet loaded in \(ms(since: started)) ms")
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        if manager == nil { try await load() }
        // Parakeet needs at least ~1 s of audio; pad short clips with silence.
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        // Each dictation is independent, so start from a fresh decoder state.
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager!.transcribe(audio, decoderState: &state, language: .english)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }
