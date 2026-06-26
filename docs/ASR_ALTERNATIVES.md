# ASR Engine Alternatives for OpenWhisp

> Research into Whisper alternatives and on-device streaming paths for a
> local-first macOS dictation app. Produced from a multi-agent web survey
> (2025), with each claim adversarially fact-checked. **Bottom line:** stay on
> whisper.cpp as the dependable base, default to **large-v3-turbo** for the best
> speed/quality, and get true low-latency streaming from a **WhisperKit** pilot.
> Everything Python-only or NVIDIA-only is unshippable in a signed `.app`.

OpenWhisp's hard constraints (every candidate is judged against these):

1. **Fully on-device on Apple Silicon** (M1+, Metal/ANE) — non-negotiable.
2. **Latency / streaming** — real partial results would be a big UX win (today
   it fakes streaming by chunking + reassembling).
3. **Accuracy**, esp. multilingual (**English + Russian** are actively used) and
   **speech→English translation**.
4. **Integration cost** from a Swift/C++ signed `.app` — a CLI/binary or a
   C/Swift library is easy; a **Python-only stack is effectively unshippable**.
5. **Permissive license** (MIT/Apache/BSD) preferred.

## Ranked summary

| # | Candidate | On-device (Apple Silicon) | True streaming | RU incl.? | Translate→EN | Integration in a Swift `.app` | License (code / weights) | Verdict |
|---|-----------|---------------------------|----------------|-----------|--------------|-------------------------------|--------------------------|---------|
| 1 | **whisper-large-v3-turbo** (existing whisper.cpp) | ✅ GGML + Metal | ❌ (same chunking as today) | ✅ 99 langs | ✅ | **Trivial** — already in the manifest | MIT / MIT | **Adopt as default** |
| 2 | **WhisperKit** (Argmax) | ✅ Swift/CoreML on ANE | ✅ LocalAgreement partials | ✅ (Whisper weights) | ✅ | **Low** — SwiftPM, ~2 lines | MIT / MIT | **Pilot for streaming** |
| 3 | **FluidAudio + Parakeet v3** | ✅ pure-Swift CoreML/ANE | partial (sliding window + EOU) | ✅ v3: 25 langs incl. ru | ❌ ASR-only | **Low** — SwiftPM | Apache-2.0 / **CC-BY-4.0** | Strong for fast transcription; **no translate** |
| 4 | **sherpa-onnx + T-one (RU)** | ✅ C API + Swift bindings | ✅ streaming zipformer / T-one | ✅ T-one is RU streaming | ❌ | **Medium** — native C lib + models | Apache-2.0 / **T-one Apache-2.0** | Best for low-latency **Russian** streaming |
| 5 | **Apple SpeechAnalyzer** (macOS 26) | ✅ OS-native | ✅ AsyncSequence volatile+final | ✅ ru_RU | ❌ | **Trivial** — but macOS 26+ only | proprietary (free) | Watch; optional backend later |
| 6 | distil-whisper | ✅ GGML | ❌ | ❌ English-only | ❌ | trivial | MIT | Reject (no RU/translate) |
| 7 | Kyutai STT (Moshi) | ✅ MLX/Rust | ✅ | ❌ EN/FR only | ❌ | medium/high | MIT-Apache / CC-BY-4.0 | Reject (no RU) |
| 8 | NVIDIA Canary | ❌ no practical Mac path | ❌ | ✅ *(v2 only)* | ✅ (its langs) | **High** — NeMo/PyTorch/CUDA | Apache / mixed | Reject (not shippable on Mac) |
| 9 | Vosk (Kaldi) | ✅ | ✅ zero-latency | ✅ | ❌ | low-medium (C API) | Apache-2.0 | Reject (WER below modern transformers) |
| 10 | faster-whisper (CTranslate2) | ❌ CPU-only on Mac | ❌ | ✅ | ✅ | **High** — Python-only | MIT | Reject (Python + no Mac GPU) |
| 11 | **SimulStreaming** (ufal, AlignAtt) | ❌ PyTorch + ≥10 GB VRAM GPU | ✅ (algorithm) | ✅ | ✅ | **High** — Python/CUDA | MIT code | **Algorithm only**, not the code |
| 12 | whisper_streaming (ufal, LocalAgreement) | ⚠️ Python | ✅ | ✅ | ✅ | high (Python) | MIT | **Algorithm only** — reimplement in Swift |
| 13 | Lightning-SimulWhisper (MLX/CoreML AlignAtt) | ✅ | ✅ | ✅ | ✅ | — | **PolyForm Noncommercial — BLOCKER** | Reject (license) |
| 14 | Moonshine | ✅ edge | partial | ❌ no Russian | ❌ | medium/high | MIT (core) | Reject (no RU) |

## The two flagged questions

### Parakeet — usable on Mac for EN+RU?

**Yes for transcription, with one real gap.**

- **On-device: confirmed.** [FluidAudio](https://github.com/FluidInference/FluidAudio)
  is a **pure-Swift, Apache-2.0 SDK** running Parakeet **v2 (EN)** / **v3
  (multilingual)** as CoreML models on the Apple Neural Engine — **no NVIDIA, no
  NeMo, no Python at runtime**, SwiftPM-installable. The most natural non-Whisper
  fit for a signed Swift `.app`.
- **Accuracy: higher ceiling than Whisper.** Parakeet v3 multilingual WER **9.7%
  edges past Whisper large-v3 9.9%** (arXiv 2509.14128) and runs much faster on
  the ANE.
- **Russian: supported but unproven.** v3 covers 25 European languages incl.
  Russian, but **no Russian-specific WER is published** — test on your own audio
  before trusting it. (v2 is English-only.)
- **The gap: no translation.** Parakeet v3 is **ASR-only** — it can't replace the
  `whisper --translate` (speech→English) flow. NVIDIA Canary would be needed for
  translation, and it isn't packaged in FluidAudio (and is its own Mac-shipping
  problem).
- **License nuance:** SDK code is Apache-2.0, but the **CoreML weights are
  effectively CC-BY-4.0** → fine for OSS, but **requires attribution** in
  NOTICE/credits.

**Verdict:** excellent optional *fast-transcription* backend; **not** a wholesale
Whisper replacement (no translate, unverified RU).

### SimulStreaming (the linked project) — adoptable?

[`ufal/SimulStreaming`](https://github.com/ufal/SimulStreaming) is a research-grade
simultaneous Whisper transcriber using the **AlignAtt** policy (reads Whisper's
cross-attention to decide when to emit tokens; ~5× less compute than the older
LocalAgreement at matched latency).

**The code is not adoptable** for OpenWhisp: it's **PyTorch + GPU-oriented** (its
README recommends ≥10 GB VRAM; "CPU is too slow for real-time"), with no
whisper.cpp/CoreML/Swift path. Shipping it means bundling Python + effectively an
NVIDIA GPU — exactly the failure mode to avoid. The one on-device AlignAtt port
([Lightning-SimulWhisper](https://github.com/altalt-org/Lightning-SimulWhisper))
is **PolyForm Noncommercial-licensed → a hard blocker** for a freely-distributed app.

**The *idea* is adoptable, though.** Both streaming policies are portable algorithms:
- **LocalAgreement-2** (re-decode a growing buffer, commit the longest prefix two
  consecutive decodes agree on; ~3.3 s latency) — the easy one. Reimplementable
  **in Swift on top of the existing warm `whisper-server`**, no new dependency.
- **AlignAtt** is lower-latency but needs whisper.cpp cross-attention exposed
  (real C++ work).

If you want native streaming with the least effort, **WhisperKit already ships a
working LocalAgreement streamer** — prefer that over hand-rolling.

## Recommended path for OpenWhisp

1. **Default to `large-v3-turbo`.** It's already in the model manifest; the only
   change needed is making it the recommended/first-run choice and fixing its
   misleading "slowest" label (it's ~2.3–4× *faster* than large-v3 at ≈ the same
   accuracy, with full RU + translate). Highest value-per-effort, zero
   architecture change.
2. **Pilot WhisperKit behind the engine abstraction** (the seams from the Phase
   2.5 `TranscriptionEngine` work make this clean) — the smallest leap to **true
   streaming partials** while keeping Whisper weights (so RU + translate survive).
   UX caveat: partials rewrite in place; stable text lands ~1.7 s in.
3. **Evaluate FluidAudio/Parakeet v3** as an optional non-translating
   fast-transcription backend (verify Russian first; add CC-BY attribution).
4. **For Russian streaming specifically**, prototype **sherpa-onnx + T-one**
   (Apache-2.0, real C API + Swift bindings). *Do not* use GigaAM (offline +
   non-commercial weights).
5. **Watch Apple SpeechAnalyzer** (macOS 26): native, free, on-device, true
   streaming, ru_RU — adopt as an optional zero-dependency backend once macOS 26
   is a reasonable baseline. (Transcription only — no translation.)

**Avoid entirely** (violate constraint #4 or #5): faster-whisper (no Mac GPU),
Canary/NeMo (Python+CUDA), the Python streaming servers, and Lightning-SimulWhisper
(non-commercial license).

## Confidence notes

- **High / verified:** on-device viability of WhisperKit, FluidAudio/Parakeet,
  sherpa-onnx, Apple SpeechAnalyzer; turbo's speed/accuracy and RU+translate;
  Parakeet v3's no-translation limit; Lightning-SimulWhisper's blocking license;
  SimulStreaming being PyTorch/GPU-bound; faster-whisper having no Mac GPU path;
  **T-one is genuinely streaming + Apache-2.0**; **GigaAM is offline + weights
  non-commercial**; **Canary-1b-v2 *does* include Russian** (rejected on stack
  grounds, not language).
- **Uncertain (test before relying):** Parakeet v3 **Russian WER** (no published
  number); FluidAudio RTF figures (vendor-reported); exact WhisperKit
  quantization WER deltas; Apple ru_RU locale (secondary sources, not Apple's own
  rendered doc).
