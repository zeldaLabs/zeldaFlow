# Vendored dependencies

## whisper.xcframework

Pre-built [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.1,
trimmed to the macOS slice this app links (the upstream artifact also ships
iOS/tvOS/visionOS slices and dSYMs — ~178 MB a macOS-only app never uses).

whisper.cpp is MIT licensed:

```
MIT License

Copyright (c) 2023-2024 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Model licenses (downloaded by scripts/setup.sh, not part of this repo)

- **Whisper large-v3-turbo** (ggml conversion) — MIT (whisper.cpp),
  model weights by OpenAI under MIT.
- **Silero VAD** — MIT.
- **Gemma 4 E2B** —
  [Apache-2.0](https://ai.google.dev/gemma/docs/gemma_4_license). Gemma 4 is
  the first Gemma release under Apache-2.0; earlier Gemma versions stay under
  Google's Gemma Terms of Use. zeldaFlow runs it strictly on-device.
