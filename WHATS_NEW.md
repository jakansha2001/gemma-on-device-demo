# What changed in the package since this demo was first built

The first version of this app used **flutter_gemma 0.13.6**. It now uses
**flutter_edge_ai 2.5.4**, with `flutter_edge_ai_litertlm` 1.19.0 and
`flutter_edge_ai_speech` 0.5.12.

This is the one place in the repo that tells the upgrade story. The talk, the
slides and the codelab describe the package as it is today; if you're moving an
older app forward, start here.

Everything below comes from the packages' published changelogs and from the
source of the versions this app depends on, checked on **30 October 2026**. The
changelog doesn't give calendar dates, so versions are the only ordering here.

---

## 1. The package is called `flutter_edge_ai` now

`flutter_gemma` was renamed in **1.11.4**. The old names kept working as
deprecated aliases until **2.0.0**, which removed them. Every companion package
was renamed to match:

| Before | Now |
| --- | --- |
| `flutter_gemma` | `flutter_edge_ai` |
| `flutter_gemma_litertlm` | `flutter_edge_ai_litertlm` |
| `flutter_gemma_mediapipe` | `flutter_edge_ai_mediapipe` |
| `flutter_gemma_speech` | `flutter_edge_ai_speech` |
| `flutter_gemma_agent` | `flutter_edge_ai_agent` |
| `flutter_gemma_onnx` | `flutter_edge_ai_onnx` |
| `FlutterGemma.initialize(...)` | `FlutterEdgeAi.initialize(...)` |

The smooth path is to move to **1.11.4 first**, run `dart fix --apply` so the
aliases rewrite your imports and class names, and only then bump to 2.x. Going
straight from an old version to 2.x means fixing every name by hand, because
`dart fix` has nothing left to map.

One thing the rename did **not** change: the native cache directory is still
`~/Library/Caches/flutter_gemma/`, and in a macOS project that still stages the
GPU libraries through CocoaPods, the build phase is still named
`[flutter_gemma] Setup LiteRT-LM macOS`. Leave both strings alone.

## 2. The core ships no engine

Since **1.0.0** the core package contains model management, chat sessions and
the response types, and nothing that can actually run a model. You add the
engine packages you need and register them at startup:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine()],
  sttBackends: const [LiteRtSttBackend()],
  ttsBackends: const [LiteRtTtsBackend()],
);
```

Forget the engine and the app still compiles. It throws at the first
`getActiveModel()` instead. The upside is that your app only ships the native
libraries for the engines you actually registered.

## 3. Breaking changes worth knowing

| Version | Change |
| --- | --- |
| 2.5.0 | The members deprecated for 2.5.0 are gone (MIGRATION.md lists them) |
| 2.4.0 | Classes that `implements InferenceModel` add `createDecider` and two getters; `extends` is unaffected |
| 2.3.0 | New embedding API (`embed`, `EmbeddingInput`) for EmbeddingGemma 2; over-long inputs throw instead of truncating |
| 2.3.0 | Internals moved to `lib/src`; an engine package imports `package:flutter_edge_ai/engine.dart` |
| 2.3.0 | The members deprecated in 1.x and 2.0 are gone |
| 2.2.1 | **For `implements InferenceModel`:** add `isClosed`; `extends` inherits the default |
| 2.2.0 | Sampling values you leave unset now come from the model file, then its family — not greedy `topK: 1` |
| 2.1.0 | `isThinking:` → **`enableThinking:`**, and `ModelRuntimeDefaults.isThinking` → `thinkingDeclared` |
| 2.0.0 | `ModelFileManager.setActiveModel` removed — use **`ensureModelReadyFromSpec`** |
| 2.0.0 | RAG APIs and the storage contracts moved to **`flutter_edge_ai_rag`**, with `_sqlite` or `_qdrant` as the store |
| 2.0.0 | The `flutter_gemma` name aliases removed |
| 1.11.0 | Anything that `implements EmbeddingModel` must add `activeBackend` and `isClosed` |
| 1.8.0 | Custom `SpeechRecognizer` implementations: `transcribe` gained a `language:` parameter |

## 4. Models and installing them

* **`installModel(...).fromHuggingFace(repo)`** (1.7.0) resolves a repo through
  its manifest, so you don't hard-code a file URL.
* **`ModelType.gemma4`** covers Gemma 4 E2B and E4B, and routes tools through
  Gemma 4's own tool-call tokens. `ModelType.qwen35` was added in 2.1.0.
* **`activationDataType`** on `getActiveModel` (1.10.0): passing `float32`
  fixes wrong digits in arithmetic on some GPUs.
* **`FlutterEdgeAi.openModel`** (2.5.0) opens several caller-owned models at
  once, each closed by whoever opened it. `FlutterEdgeAiPlugin.createModel` is
  deprecated in its favour.
* Two defaults that have not changed, and still catch people out:
  `installModel` defaults `fileType` to `.task`, and `createChat` falls back to
  `ModelType.gemmaIt` when `modelType` is omitted. Both are still true in 2.5.4.

## 5. Function calling got a real loop

* **`generateChatResponseWithTools`** runs the whole call-and-answer loop for
  you: it takes `onToolCall`, a `maxToolTurns` cap and an optional
  `isCancelled`, and feeds each result back until the model replies in text.
* **`ParallelFunctionCallResponse`** arrives when the model asks for several
  tools at once. A hand-written listener has to handle it; the helper above
  already does.
* **`ToolChoice`** (added in 0.12.8) selects `auto`, `required` or `none`.
  Read the caveat in the docs before relying on it: on Gemma 4 and
  FunctionGemma `.litertlm`, `required` is silently treated as `auto`, because
  the runtime payload has no `tool_choice` field.
* `Tool.parameters` defaults to an empty map, and a tool declared without a
  schema fails generation with `Failed to start streaming (code: 13)`. A tool
  that takes no arguments still needs
  `{'type': 'object', 'properties': <String, dynamic>{}}`.

## 6. Speech became a whole subsystem

`flutter_edge_ai_speech` went from "moonshine-tiny only" to a full loop:

| Version | What arrived |
| --- | --- |
| 0.3.0 | `VoiceSession`: a push-to-talk STT → LLM → TTS loop, with barge-in |
| 0.4.0 | Whisper-tiny STT, and Parakeet-CTC on desktop |
| 0.4.1 | Qwen3-TTS, multilingual |
| 0.4.2 | Inflect-Nano-v2, English-only and very fast, plus `onToolCall` inside a spoken turn |
| 0.4.3 | `VoiceSession(streamAudio: true)`: clause-by-clause synthesis overlapped with the LLM stream |
| 0.5.0 | Whisper's output language became a parameter instead of hardcoded English |
| 0.5.2 | Fixed Inflect's garbled speech — the encoder now gets the blank tokens it was trained with |
| 0.5.7 | `VoiceSession.runAudioTurn`: the model hears the recording, with no speech-to-text in the way |
| 0.5.11 | A closed recognizer or synthesizer fails through the Future it returned, instead of hanging |

Two things to take from that list. **`streamAudio: true` removes the need to
split a reply into sentences yourself**, which is what this app used to do.
And since the 0.5.2 fix, Inflect is the obvious default for an English voice
loop: on this M1 Mac, synthesizing one 4.8-second sentence takes Inflect 0.6 s
against Matcha's 15.8 s, and Whisper transcribes both back word-perfect.

Speech-to-text models still have a fixed window — Moonshine Tiny five seconds,
Whisper Tiny thirty — and anything longer is truncated without an error.

## 7. Gemma 4 can just listen

Gemma 4 takes audio as an input, so the whole speech-to-text step is optional.
Open the chat with `supportAudio: true` and send the recording itself:

```dart
await chat.addQueryChunk(Message.audioOnly(audioBytes: wavBytes, isUser: true));
```

Two models become one, and nothing is lost to a wrong transcript.
`VoiceSession.runAudioTurn` (speech 0.5.7) is the same thing inside the
ready-made loop.

Two details that cost time if you don't know them. `getActiveModel` has to be
told `supportAudio: true` as well — the chat flag alone isn't enough. And
litertlm 1.14.0 changed the order of a mixed message so that Gemma 4 gets its
audio *after* the text, because the package measured that it answers more
spoken turns that way; `getActiveModel(multimodalOrder:)` overrides it. A
message that is only audio sidesteps the question.

## 8. New packages worth a look

* **`flutter_edge_ai_builtin_ai`** uses the model built into the OS or browser:
  Gemini Nano on Android, Apple Foundation Models on iOS and macOS 26+,
  Phi Silica on Windows, the browser Prompt APIs on web.
* **`flutter_edge_ai_diagnostics`** reports what a model actually costs in
  memory, read from the OS.
* **`flutter_edge_ai_agent`** builds reusable skills on top of function calling.
* **Agent skills for the package itself** (1.8.2): `dart run skills@ get --all`
  teaches an AI assistant how the package works.

## 9. Platform floors today

* Flutter **3.44+**, Dart **3.12+** — the native libraries come through Dart
  build hooks (Native Assets).
* **Android:** minSdk **30** for `.litertlm` inference, embeddings and speech;
  arm64 only. MediaPipe `.task` has no such floor.
* **iOS:** 15.0, or 16.0 if you add `flutter_edge_ai_mediapipe`.
* **macOS:** **14.0**, Apple Silicon only. With Swift Package Manager on — how
  Flutter 3.47 behaves unless you turn it off — litertlm 1.19.0 ships the two GPU
  companion libraries in its own Swift package and there is nothing to add. The
  `post_install` block in `macos/Podfile` is for apps that have Swift Package
  Manager off; without either, the build succeeds and the first model load
  fails.
* **Web:** `.litertlm` is an early preview — text and function calling, no
  vision or audio.

## 10. What this demo changed because of all that

* Renamed every import and `FlutterGemma` → `FlutterEdgeAi`.
* `isThinking:` → `enableThinking:` on the vision and thinking screens.
* Text-to-speech switched from Matcha to Inflect-Nano-v2.
* Android `minSdk` raised from 26 to 30.
* The sentence-splitting voice loop in `lib/gemma/voice_turn.dart` is kept
  because it is the part of the demo that shows the pipeline on stage. If you
  are starting fresh, use `VoiceSession(streamAudio: true)` instead.
* The voice screen got a switch for the audio route. Off, Whisper transcribes
  and Gemma answers the text; on, Gemma answers the recording and Whisper sits
  out. `VoiceTurn` takes an optional `respondToAudio` callback for that, and
  the pipeline bar on screen strikes out the step that didn't run.
* macOS moved onto Swift Package Manager: the `post_install` block and the
  `[flutter_gemma] Setup LiteRT-LM macOS` build phase are both gone, and the
  deployment target went from 12.0 to 14.0.
