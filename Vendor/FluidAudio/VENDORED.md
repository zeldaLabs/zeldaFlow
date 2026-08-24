# Vendored: FluidAudio v0.15.5 (subset)

- **Origin**: https://github.com/FluidInference/FluidAudio, tag `v0.15.5`
  (2026-07-07). Code license: Apache-2.0 (see `LICENSE` here).
- **Why vendored, not SPM**: no `Package.swift` compiles on this beta CLT
  (PackageDescription swiftinterface/dylib mismatch — same reason
  `scripts/build-app.sh` exists, ADR 10). The subset is compiled by
  `build-app.sh` as a separate `-swift-version 6` static module
  (`build/libFluidAudio.a`) because upstream is Swift-6-only while the app
  builds `-swift-version 5`.
- **Models**: NOT in this tree. `FluidInference/speaker-diarization-coreml`
  (CC-BY-4.0, ungated) is downloaded by `scripts/setup.sh` into
  `~/Library/Application Support/zeldaFlow/models/diarizer/`. Attribution:
  pyannote `speaker-diarization-community-1` (segmentation) + WeSpeaker
  (embeddings), converted to Core ML by FluidInference.

## What is kept

- `Sources/FluidAudio/Diarizer/**` — the whole diarizer (offline pipeline is
  the one zeldaFlow uses; streaming kept because it shares Core types)
- `Sources/FluidAudio/Shared/**`, `Sources/FluidAudio/VAD/**`
- `Sources/FluidAudio/{FluidAudioSwift,ModelNames,ModelRegistry}.swift`
- `Sources/FluidAudio/ASR/Parakeet/Unified/UnifiedConfig.swift` and
  `Sources/FluidAudio/TTS/PocketTTS/PocketTtsConstants.swift` — type-only
  files `ModelNames.swift` cannot compile without
- `Sources/FastClusterWrapper/**` (C++), `Sources/MachTaskSelfWrapper/**` (C)

## What is pruned

ASR (Parakeet/SenseVoice), TTS, ITN — including their model downloads and
every heavy dependency. Pruning rule: start from the offline diarizer's
import graph, add files only when the compiler asks.

## Local modifications

Upstream files are byte-identical. The ONLY addition is
`Sources/FluidAudio/VendorShims.swift`, which re-declares two tiny helpers
whose upstream homes were pruned with the ASR decoder:
`makeBlasIndex` (VBxClustering) and `MLMultiArray.resetData/copyData`
(MLArrayCache) — rewired to a local error type instead of `ASRError`.

## Third-party code inside this subset

FluidAudio itself is Apache-2.0 (`LICENSE` here). Two of the kept files carry
their own upstream licenses, reproduced in `ThirdPartyLicenses/` as upstream
does — both are required to travel with any redistribution:

- **fastcluster** — `Sources/FastClusterWrapper/fastcluster_internal.hpp`.
  BSD-2-Clause: © 2011 Daniel Müllner (to package 1.1.23), © Google Inc.
  thereafter. Text: `ThirdPartyLicenses/fastcluster-LICENSE.md`.
- **VBx** — `Sources/FluidAudio/Diarizer/Offline/Clustering/VBxClustering.swift`
  and `Diarizer/Offline/Extraction/PLDATransform.swift`, ported from the VBx
  algorithm by BUT Speech@FIT (Brno University of Technology). Apache-2.0,
  © 2021-2024 BUT Speech@FIT. Text: `ThirdPartyLicenses/vbx-LICENSE.md`.

Upstream FluidAudio v0.15.5 ships no `NOTICE` file, so there is none to
propagate under Apache-2.0 §4(d).

## Upgrading

1. Download the new tag's tarball; diff `Sources/FluidAudio/Diarizer` +
   `Shared` + `VAD` against this tree.
2. Re-copy the kept set, keep `VendorShims.swift`, re-run
   `scripts/build-app.sh` and chase any new compile errors the same way
   (copy type-only files, or extend the shim for pruned helpers).
3. Re-copy `ThirdPartyLicenses/` — upstream may have added entries.
4. Check upstream's model-repo pin (`ModelNames.swift`) — if the diarizer
   model filenames changed, update `scripts/setup.sh`'s download list.
