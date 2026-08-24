# Performance

Measured performance of zeldaFlow, zeldaLabs' local-first voice dictation app, on real hardware with the full pipeline — Whisper large-v3-turbo (q8_0, Metal) with Silero VAD, plus Gemma 4 E2B cleanup via a local `llama-server`.

**Machine:** Apple M4 Pro (14 cores), 24 GB RAM · **Date:** 2026-07-28 · **Build:** `scripts/build-app.sh` release bundle

## Headline numbers

| Metric | Result |
|---|---|
| Model load + warm-up (warm) | ~750 ms |
| Model load, first-ever launch | ~8.5 s (one-time)† |
| First load after installing the Core ML encoder | ~17 s (one-time ANE compile)† |
| Transcribe 3.08 s clip | 920–1020 ms |
| Transcribe 19.9 s clip | 1067 ms |
| Transcribe 48 s clip | 1516 ms (~30x real-time) |
| Gemma cleanup | 157–727 ms |
| Peak RSS during transcription | ≈ 1.1 GB (1,076,992–1,097,248 KB) |
| Idle app RSS | ≈ 93 MB† |

† measured ad hoc, outside the scripted runs.

The practical takeaway: after you release Fn, a typical utterance is transcribed in about a second, and cleanup adds a fraction of a second on top. Longer dictation barely costs more — Whisper's per-pass overhead dominates short clips, so throughput *improves* with length (~3x real-time at 3 s, ~19x at 20 s, ~30x at 48 s).

## Detailed results

Three runs of the short clip, then one each of the medium and long clips. All numbers were produced by driving `--selftest` with the loop shown in [Reproduce it yourself](#reproduce-it-yourself); see [Methodology](#methodology).

| Run | Audio | Load + warmup | Transcribe | Cleanup | Peak RSS |
|---|---|---|---|---|---|
| short-run1 | 3.08 s | 738 ms | 1016 ms | 357 ms | 1,088,128 KB |
| short-run2 | 3.08 s | 776 ms | 923 ms | 157 ms | 1,076,992 KB |
| short-run3 | 3.08 s | 753 ms | 918 ms | 163 ms | 1,077,376 KB |
| medium | 19.89 s | 751 ms | 1067 ms | 727 ms | 1,090,896 KB |
| long-48s-stress | 47.98 s | 750 ms | 1516 ms | 426 ms | 1,097,248 KB |

Notes:

- **Load + warmup** is `WhisperEngine.loadAndWarmUp`: model load plus a short warm-up decode that pre-pays Metal graph compilation, so the first real dictation doesn't stall. ~750 ms is the *warm* number (model file in the OS page cache). The very first launch ever is ~8.5 s; the first launch after installing the optional Core ML encoder is ~17 s while macOS compiles the model for the Neural Engine — both one-time costs.
- **Cleanup** varies with output length: ~160 ms for a one-liner, ~730 ms for a ~340-character paragraph. The first run's 357 ms includes server warm-up. Cleanup runs on a local `llama-server` (Gemma 4 E2B Q4_0) with a hard timeout and raw-text fallback, so it can never block dictation.
- **Memory:** peak RSS during active transcription is ≈ 1.05–1.10 GB (the resident Whisper Metal context dominates). The app sitting idle measures ≈ 93 MB RSS — the model weights are mmap-backed, so clean pages don't stay resident when nothing is running.
- The same benchmark run finished with `--evalcommands`: all 23 command-grammar and confirmation-gate pins hold.

## Methodology

The benchmark drives zeldaFlow's built-in self-test (`zeldaFlow --selftest <wav>`), which runs the exact production pipeline — model load + warm-up, Whisper transcription with the app's real prompt and Silero VAD, then Gemma cleanup — against a WAV file instead of the microphone.

- **Test audio** is synthesized speech: `say` renders the text to AIFF, `afconvert` converts to 16 kHz mono PCM (Whisper's input format). Three clips: short command (3.08 s), medium dictation (19.89 s), long stress clip (47.98 s).
- **Variance:** the short clip is run 3 times; spread on transcription was 918–1016 ms and on load 738–776 ms.
- **Peak RSS** is sampled by a shell loop polling `ps -o rss=` on the self-test process every 0.5 s and keeping the maximum.
- Each run is a fresh process, so load time is measured every time; runs after the first are page-cache-warm.

## Stress notes

- **48 s of continuous dictation works fine:** 1516 ms to transcribe, no memory growth beyond the usual ~1.1 GB peak, cleanup normal.
- **Whisper collapses looped identical sentences.** The long clip repeats one sentence for 48 s; the transcript contains it only twice. This is Whisper's repetition suppression reacting to pathologically repetitive *synthetic* audio — expected model behavior, not a pipeline defect. Real long-form dictation (varied sentences) does not trigger it.

## Long-form dictation (2.5 / 6.2 / 12.3 minutes)

A second run (same day, same machine) pushed varied synthesized meeting-notes
prose — not loops — through the full pipeline at meeting-length durations:

| Clip | Audio | Transcription | Speed vs. real time | Peak RSS |
|---|---:|---:|---:|---:|
| 2.5-minute dictation | 149.6 s | 4.1 s | 36× | 1.10 GB |
| 6.2-minute dictation | 373.9 s | 9.9 s | 38× | 1.15 GB |
| 12.3-minute dictation | 739.2 s | 18.3 s | 40× | 1.25 GB |

Transcription scales linearly (~40× real time) and memory grows only with the
audio buffer. All raw transcripts were complete.

**This test caught a real data-loss bug.** Gemma's cleanup server runs with a
4096-token context; the 6.2- and 12.3-minute transcripts exceeded it and the
"cleaned" output came back as roughly the first ~210 words — a 12-minute
dictation would have pasted only its first minute, silently. Fixed the same
day in `CleanupService`: transcripts beyond ~4,500 characters now skip Gemma
and take the deterministic light-cleanup path (every word kept), and any
cleanup output that shrinks below a third of its input is rejected as
truncation, falling back to the raw transcript. Long-form runs after the fix
log `exceeds the cleanup context budget — falling back to light cleanup` and
`--selftest` prints `cleanup: fell back to raw`.

Note for *live* long dictation: the default max recording length is 5 minutes
(Settings → Dictation → "Max recording", up to 20 minutes). The file-driven
pipeline above has no cap; a real 10-minute mic session needs the setting
raised first.

## Soak, accuracy, contention, and edge cases

Same day, same machine, all against the installed `/Applications` binary:

- **Soak — no thermal drift.** Six consecutive 12.3-minute transcriptions
  (74 minutes of audio, back-to-back GPU/ANE load): 18.19–18.65 s per run,
  ±1.2% spread, the *last* run the fastest. The cleanup context-budget
  fallback held on every cycle.
- **Accuracy (synthesized speech).** Word error rate of the raw transcript
  against the exact script fed to `say`, across every clip: 3 s → 0.0%,
  20 s → 1.8%, 2.5 min → 0.2%, 6.2 min → 1.5%, 12.3 min → 1.8%. Synthetic
  studio-clean audio flatters any STT model — treat these as an upper bound,
  not a field measurement.
- **Parallel contention degrades gracefully.** Two simultaneous 20 s
  transcriptions in separate processes: both succeed at 1.84/1.87 s vs
  1.07 s solo. (The app itself serializes all inference on one queue, so
  this is a worse case than production ever creates.)
- **Silence is rejected, fast.** A 2 s all-zero WAV: VAD strips everything,
  transcription returns empty in 6 ms, `--selftest` exits 2 ("empty
  transcript") — the pipeline refuses to hallucinate text for silence.
- **Language stays the language spoken.** A Spanish clip (default
  `language = auto`) transcribes to Spanish, accents intact, never
  translated; cleanup preserves it.
- **Insertion verified end-to-end.** `--insert-test` against a scratch
  TextEdit document: `insert result: pasted`, the document's text read back
  identical via AppleScript, clipboard restored.

## Multi-monitor performance

With 2–3 external displays, three GPU consumers stack on the same chip:

1. **WindowServer** compositing every attached display,
2. **Whisper's Metal encoder** — without the Core ML encoder installed, the entire model (encoder + decoder) runs on the GPU,
3. **zeldaFlow's live-preview loop**, which re-transcribes up to a 12 s tail of the recording on a ~150 ms cadence while you speak.

Under that contention a preview pass stretches from ~0.2 s to 1 s+, and because preview and final passes serialize on the same inference queue, the preview was compounding the very contention that slowed it down. Two mitigations shipped today:

- **Adaptive preview cadence** (`Sources/zeldaFlow/AppState.swift`): the pause between preview passes now scales with the measured STT latency of the previous pass — `min(1.5, max(0.15, sttSeconds * 1.5))` — so on an uncontended GPU the preview stays snappy (0.15 s floor), and on a contended one it backs off toward 1.5 s instead of piling on. The final full-quality pass is what actually gets inserted, so preview back-off costs nothing in accuracy.
- **Optional Core ML encoder** (`scripts/setup.sh`): downloads `ggml-large-v3-turbo-encoder.mlmodelc` (1.1 GB), which moves Whisper's encoder — the bulk of the compute — off the GPU and onto the Neural Engine. Dictation works fine without it (Metal fallback), but the ANE keeps it fast when the GPU is busy compositing displays. First load after installing pays the ~17 s one-time compile mentioned above.

## Reproduce it yourself

```sh
# Build (see README for signing setup) and fetch models
./scripts/build-app.sh
./scripts/setup.sh          # models incl. the optional Core ML encoder

# Synthesize a 16 kHz mono test clip
say -o /tmp/short.aiff "Open Safari and search for the weather in Melbourne today."
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/short.aiff /tmp/short.wav

# Run the full pipeline against it (prints load, transcribe, cleanup timings)
./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --selftest /tmp/short.wav

# Peak-RSS sampling around a run
./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --selftest /tmp/short.wav & pid=$!
peak=0
while kill -0 $pid 2>/dev/null; do
  rss=$(ps -o rss= -p $pid | tr -d ' ')
  [ -n "$rss" ] && [ "$rss" -gt "$peak" ] && peak=$rss
  sleep 0.5
done
echo "peak RSS: ${peak} KB"

# Command-grammar and confirmation-gate pins
./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --evalcommands
```

Run the short clip a few times to separate cold-cache from warm-cache load times.

## Limitations

Honest caveats about these numbers:

- **Single machine.** Everything above is one M4 Pro with 24 GB. Older or base-tier Apple Silicon will be slower; nothing here predicts by how much.
- **Synthetic speech.** `say` output is clean, accent-free, and perfectly paced — real microphones add noise, room reverb, and disfluencies. The measured 0–1.8% word error rate reflects that studio-clean input; treat it as an upper bound. (It still mishears like real audio does: the medium clip's raw transcript rendered "pill panel" as "PIL panel".)
- **Soak covered to ~74 processed minutes.** Six back-to-back 12.3-minute transcriptions showed no thermal drift (±1.2%); hour-long *continuous* mic sessions on a hot chassis remain unmeasured.
- **RSS sampling at 0.5 s** can miss short-lived allocation spikes between samples.
- Multi-monitor numbers are mechanism-verified (code + logs), but the contention scenario hasn't been re-benchmarked in a controlled 2–3 display A/B on this machine.
