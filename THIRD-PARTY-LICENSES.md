# Third-party licenses

zeldaFlow is Apache-2.0 ([LICENSE](LICENSE)). This page lists everything else
that ships in the repository or lands on your Mac when you run
`scripts/setup.sh`, with its license and what that license asks of you.

Two things are worth knowing before the table:

- **The model weights are not in this repository.** They are downloaded at
  setup time into `~/Library/Application Support/zeldaFlow/models/`, from
  public Hugging Face URLs. Nothing is fetched at app runtime.
- **Everything the setup script downloads is permissively licensed.** Whisper
  and Silero are MIT, Gemma 4 is Apache-2.0 (Google moved Gemma to Apache-2.0
  with the Gemma 4 release in April 2026; earlier Gemma versions stay under
  the use-restricted Gemma Terms of Use), and the optional diarizer models are
  CC-BY-4.0, which asks for attribution wherever you present their output.
  Gemma is still optional — dictation works without it; you lose AI cleanup,
  voice commands, and meeting notes, and the app says so rather than failing.

## Bundled in this repository

| Component | Where | License | Notes |
|---|---|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.1 | `Vendor/whisper.xcframework/` | MIT, © 2023-2024 The ggml authors | Pre-built, trimmed to the macOS slice. Full text in [`Vendor/README.md`](Vendor/README.md) |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) v0.15.5 (subset) | `Vendor/FluidAudio/` | Apache-2.0 | Speaker diarization. Provenance, kept/pruned set, and the one local modification: [`Vendor/FluidAudio/VENDORED.md`](Vendor/FluidAudio/VENDORED.md). Upstream ships no `NOTICE` |
| [fastcluster](https://github.com/fastcluster/fastcluster) | `Vendor/FluidAudio/Sources/FastClusterWrapper/` | BSD-2-Clause, © 2011 Daniel Müllner; © Google Inc. from 1.1.24 | Centroid-linkage clustering. Text: [`ThirdPartyLicenses/fastcluster-LICENSE.md`](Vendor/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md) |
| VBx | `Vendor/FluidAudio/Sources/FluidAudio/Diarizer/Offline/` | Apache-2.0, © 2021-2024 BUT Speech@FIT | Variational Bayes speaker clustering, ported from the Brno University of Technology project. Text: [`ThirdPartyLicenses/vbx-LICENSE.md`](Vendor/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md) |

## Downloaded by `scripts/setup.sh`

| Component | License | Notes |
|---|---|---|
| Whisper large-v3-turbo (ggml q8_0, 874 MB) | MIT | Weights by OpenAI under MIT; ggml conversion by whisper.cpp |
| Whisper large-v3-turbo Core ML encoder (1.1 GB, optional) | MIT | Neural Engine encoder; the app runs without it |
| Silero VAD v6.2 (1 MB) | MIT | Voice-activity detection |
| Gemma 4 E2B-it (Q4_0, 2.8 GB) | [Apache-2.0](https://ai.google.dev/gemma/docs/gemma_4_license) | Gemma 4 is the first Gemma release under Apache-2.0 (April 2026); earlier Gemma versions remain under Google's use-restricted Gemma Terms of Use. Powers AI cleanup, voice commands, and meeting notes. Runs strictly on-device |
| Speaker-diarization Core ML models (~100 MB, optional) | CC-BY-4.0 — **attribution required** | Converted by FluidInference from [pyannote speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) (segmentation) and WeSpeaker (embeddings) |

## Runtime dependencies you install yourself

| Component | License | Notes |
|---|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-server`) | MIT | Installed via Homebrew by `scripts/setup.sh`. Hosts Gemma. Not bundled |
| [Claude Code CLI](https://claude.com/claude-code) | Anthropic's terms | Optional. Only used for agent mode, which is opt-out and gated behind an explicit keypress every time. Not bundled, not required |

## If you redistribute zeldaFlow

Apache-2.0 asks you to keep [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE) with
the code. The BSD-2 and Apache-2.0 components above ask the same of their own
license texts, which is why they live in the tree rather than being referenced
by link. The CC-BY-4.0 diarizer models require attribution wherever you present
their output. And note the marks are not covered by any of this —
see [TRADEMARK.md](TRADEMARK.md).
