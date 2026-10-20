# LocalFlow

A push-to-talk dictation app for macOS that works like Wispr Flow but runs entirely on your Mac. No audio or text leaves the machine.

Hold the hotkey (Right Option by default), speak, and let go. The cleaned-up text is pasted wherever your cursor is.

## How it works

```
hold key ──► microphone (16 kHz) ──► Parakeet TDT 0.6B v3 on the Neural Engine ──► raw transcript
release  ──► Qwen3-4B-Instruct via llama.cpp (localhost only) ──► cleaned text ──► pasted at cursor
```

- **Speech-to-text:** NVIDIA Parakeet TDT 0.6B v3 through the FluidAudio library. It runs on the Apple Neural Engine and adds punctuation itself.
- **Cleanup:** Qwen3-4B-Instruct (Q4_K_M quantization) served by `llama-server` on `127.0.0.1:8178`. It removes fillers, stutters and false starts, applies self-corrections ("2, no wait, 3"), fixes grammar and formats lists. The instructions are in `Sources/LocalFlow/Cleaner.swift` (`Prompt`).
- **Safety net:** if the LLM takes longer than 4 s, or its output looks like it answered your words instead of cleaning them, a rule-based cleanup is pasted instead. Short phrases with no fillers skip the LLM entirely.
- **Dictionary:** menu bar ▸ Edit Dictionary. Add names and jargon one per line, and the LLM will spell them that way.

## Setup

1. Install the Xcode Command Line Tools: `xcode-select --install`
2. Download the LLM runtime and model (about 2.5 GB): `./setup.sh`
3. Create the signing certificate (one time; asks for your password): `scripts/make-signing-cert.sh`. Without a *trusted* signing certificate, macOS silently refuses the Input Monitoring and Accessibility permissions that the hotkey and pasting need.
4. Build the app: `./build.sh` → `build/LocalFlow.app`. The script calls `swiftc` directly rather than `swift build`, because the package manager in this Mac's Command Line Tools install is broken. The first build compiles FluidAudio from `vendor/`, which takes about a minute.
5. Open `build/LocalFlow.app`. Grant **Microphone**, **Input Monitoring**, and **Accessibility** when prompted (System Settings ▸ Privacy & Security), then restart LocalFlow from its menu so the grants take effect. On first launch it downloads the Parakeet speech model, then works offline.

LocalFlow turns on **Start at Login** the first time it runs, and it appears under System Settings ▸ General ▸ Login Items. To turn it off, use menu bar ▸ Start at Login.

Pick the hotkey from menu bar ▸ Hotkey: Left Control, Right Option (the default), Fn, or Right Command. If you press another key while holding it (Control-C, for example), LocalFlow treats it as a shortcut and throws the recording away.

If you pick **Fn** as the hotkey, set System Settings ▸ Keyboard ▸ "Press 🌐 key to" ▸ **Do Nothing**, so macOS doesn't open the emoji picker.

## Testing without the hotkey

```bash
.build-manual/LocalFlow --test-text "um so I think we should uh ship it on Friday no wait Monday"
.build-manual/LocalFlow --test-audio sample.wav
```

`scripts/test-prompt.sh` runs every line in `scripts/cases.txt` through the cleanup model. Use it after you change the instructions.

## Evaluating cleanup quality

`eval/cases.jsonl` has 123 graded dictations across 14 categories: fillers, stutters, self-corrections, lists, spoken formatting, questions and prompt injections that must not be answered, numbers, technical jargon, email, fluent text that must pass through unchanged, app tone, and "traps" where words like "like" or "actually" carry meaning. Each case lists phrases that must and must not appear, plus a minimum similarity to the expected text.

```bash
.build-manual/LocalFlow --eval eval/cases.jsonl eval/results/latest.jsonl
```

This runs the real pipeline (fast path, LLM, safety checks) and prints failures, per-category scores, and latency. Results so far, with Qwen3-4B:

| Version | Passed | Median latency |
|---|---|---|
| First prompt | 97/123 (79%) | 295 ms |
| Tuned prompt, fast-path triggers, word-reuse safety check | 116/123 (94%) | 349 ms |

With spoken-punctuation handling (16 more cases, 139 total): 132/139 (95%), median 357 ms.

The remaining failures are judgment calls where the 4B model over-edits ("He said that that was" → "He said that was", or dropping "I think").

Model comparison on the same build (one grading bug, which marked Llama's correct "March 5th" as wrong, is counted as a pass):

| Model | Size | Passed | Median latency | Slowest 5% |
|---|---|---|---|---|
| Qwen3-4B-Instruct-2507 (default) | 2.5 GB | 115/123 (93%) | 349 ms | 723 ms |
| Llama 3.1 8B Instruct | 4.9 GB | 118/123 (96%) | 616 ms | 1,276 ms |

To try the 8B: `defaults write local.localflow model Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf`, then restart LocalFlow. To go back: `defaults delete local.localflow model`.

Each line prints the result and how long it took. Timings for real dictations are written to `~/Library/Logs/LocalFlow.log`.

## Files

| Path | What |
|---|---|
| `~/Library/Application Support/LocalFlow/llama/` | llama.cpp runtime |
| `~/Library/Application Support/LocalFlow/models/` | Cleanup model |
| `~/Library/Application Support/LocalFlow/dictionary.txt` | Your custom words |
| `~/Library/Logs/LocalFlow.log` | Timings and errors |
