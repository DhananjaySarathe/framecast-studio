# Research notes: live speech-to-text for the director

Raw notes from a research pass on 2026-10-21, with sources as cited. Summarised in docs/AI-DIRECTOR-RESEARCH.md. Our own measurements on this Mac are in `stt-latency/`.

**Short answer:**
- **Primary:** Apple SpeechAnalyzer + SpeechTranscriber, on-device.
- **Fallback, or for vocabulary boosting and diarization:** FluidAudio (Parakeet on the Neural Engine).
- **Cloud:** comparison only, opt-in.
- SpeechTranscriber currently ignores custom vocabulary, so match the transcript against the script with a name-alias table.

## Apple Speech (on-device)
**Checked on this Mac (Command Line Tools build, macOS 27.0.1 SDK):**
- `SpeechTranscriber.isAvailable` is true.
- 45 locales (DictationTranscriber: 54); `AssetInventory.maximumReservedLocales` is 5.
- Preferred format is 16 kHz mono Int16; SpeechDetector (voice detection) is installed.
- The model is fetched once through `AssetInventory` and runs outside the app ([WWDC25 277](https://developer.apple.com/videos/play/wwdc2025/277/)).

**New in macOS 27** ([Speech updates, June 2026](https://developer.apple.com/documentation/updates/speech)):
- `CaptureInputSequenceProvider` connects an AVCaptureDevice or existing AVCaptureSession straight to AnalyzerInput ([docs](https://developer.apple.com/documentation/speech/captureinputsequenceprovider)).
- Also new: `AnalyzerInputConverter`, `AssetInputSequenceProvider`, `AnalyzerInput(buffer: CMReadySampleBuffer)` and `ignoresResourceLimits`.
- No new model, diarization or vocabulary features.

**Timing:**
- `.volatileResults` gives provisional text "almost as soon as spoken"; `.fastResults` trades accuracy for speed ([docs](https://developer.apple.com/documentation/speech/speechanalyzer)).
- Finals take about 2.1 s ([forum 794720](https://developer.apple.com/forums/thread/794720)).
- **Decision:** trigger from volatile text and use finals to correct the position.

**Accuracy** (LibriSpeech, M2 Pro, July 2026, [GIGAZINE / Inscribe](https://gigazine.net/gsc_news/en/20260714-apple-speech-analyzer-benchmark/)):

| Engine | Clean WER | Other WER |
|---|---|---|
| SpeechAnalyzer | 2.12% | 4.56% |
| Whisper Small | 3.74% | 7.95% |
| SFSpeechRecognizer | 9.02% | 16.25% |

**Custom vocabulary:**
- Only DictationTranscriber uses `contextualStrings` and custom language models; SpeechTranscriber "does not currently" ([forum 811083](https://developer.apple.com/forums/thread/811083)).
- Our test agrees: adding "Opus" did not fix "OPA".

**Legacy SFSpeechRecognizer:** one-minute limit and throttling ([docs](https://developer.apple.com/documentation/speech/sfspeechrecognizer)). Don't build on it.

## Open-source on Apple Silicon
- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** (v0.17.7, Apache-2.0, Swift package, Neural Engine; M4 Pro figures from its [docs](https://docs.fluidinference.com/introduction.md)):
  - Parakeet TDT 0.6B: 2.1–2.5% WER, about 210× real time.
  - Parakeet EOU 120M streaming: 160 ms chunks, 4.9% WER.
  - CTC vocabulary boosting: 99.3% precision / 85.2% recall.
  - Silero VAD, a beta echo canceller, and streaming diarization (LS-EEND, Sortformer).
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** (MIT): about 0.46 s latency and 2.2% WER ([arXiv 2507.10860](https://arxiv.org/abs/2507.10860)). Custom vocabulary and real-time speaker labels are Pro-only and paid ([pricing](https://www.argmaxinc.com/pricing)). Runs on the GPU, so it competes with the video pipeline.
- **NVIDIA Nemotron 3.5 ASR streaming:** no Apple runtime.
- **Moonshine v2** (MIT): about 100 ms claimed ([paper](https://arxiv.org/abs/2602.12241)).
- **Kyutai STT:** 0.5 s / 2.5 s delay, MLX.
- **Voxtral Realtime:** Apache-2.0, no Swift path.
- **Voice detection:** Apple SpeechDetector or [Silero VAD](https://github.com/snakers4/silero-vad).

## Cloud streaming (per hour of audio, October 2026)

| Service | Price | Latency | Vocabulary |
|---|---|---|---|
| [Deepgram](https://deepgram.com/pricing) Flux | $0.39 promo / $0.46 | ~260 ms end of turn | keyterms, mid-stream updates |
| Deepgram Nova-3 | $0.29 | | keyterms |
| [AssemblyAI](https://www.assemblyai.com/pricing) Universal-3.6 Pro RT | $0.45 | ~150 ms P50 | 100 keyterms included |
| AssemblyAI Universal-Streaming | $0.15 | | |
| [OpenAI](https://developers.openai.com/api/docs/pricing) gpt-live-transcribe | $1.02 | | keywords/prompt; no word timestamps |
| [Gemini](https://ai.google.dev/gemini-api/docs/pricing) 3.5 transcribe-live | ~$0.54 | | free tier |
| [ElevenLabs](https://elevenlabs.io/pricing/api) Scribe v2 RT | $0.39 | ~150 ms | |
| [Speechmatics](https://www.speechmatics.com/pricing) | $0.45–0.80 | partials < 500 ms | |
| Azure | $1.00 | | 5 free hours/month |
| [Soniox](https://soniox.com/pricing) rt-v5 | $0.12 | | diarization and context included |

## Recommendation
- Use SpeechTranscriber with volatile + fast results and `.audioTimeRange`, plus SpeechDetector.
- Feed it through `CaptureInputSequenceProvider` on Framecast's capture session.
- Call `prepareToAnalyze` when the show is armed; download the model during onboarding.
- Cues fire on stable volatile text, matched fuzzily and phonetically against the script, with an alias table.
- Optional: a DictationTranscriber side channel using a custom language model built from the script.
- Transcribe guests per LiveKit track, so no diarization is needed.
- Fallback: FluidAudio Parakeet.

## Risks
1. No custom vocabulary in SpeechTranscriber.
2. Volatile text can change after it has triggered a cue, so cues must be reversible.
3. One-time model download, and 5 reserved locale slots.
4. Some APIs are macOS 27 only.
5. Guest audio bleeding into the mic.
6. Neural Engine and GPU contention.
7. The speech-recognition permission requirement is unverified.
8. Some figures are vendor-reported.
