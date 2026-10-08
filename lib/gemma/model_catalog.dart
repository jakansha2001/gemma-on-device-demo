import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// Every model the demo installs, in one place.
///
/// The headline change from v1: the LLM is **Gemma 4 E2B in `.litertlm`
/// format**, published by `litert-community`. Two consequences worth calling
/// out on stage:
///
///  * **No Hugging Face token.** v1 used `google/gemma-3n-E2B-it-litert-preview`,
///    a gated repo — the download 401s until you accept a licence and ship a
///    token in the app. This repo is public, so the `.env` file, the
///    `flutter_dotenv` dependency and the whole "get a token first" setup step
///    are gone.
///  * **One file, three platforms.** `.litertlm` runs on Android, iOS *and*
///    desktop through the same `dart:ffi` LiteRT-LM engine. The older `.task`
///    format is MediaPipe-only and cannot load on desktop at all, which is why
///    this app depends on `flutter_gemma_litertlm` and not
///    `flutter_gemma_mediapipe`.
abstract final class Models {
  // --- The LLM ------------------------------------------------------------
  static const llmUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
  static const llmFilename = 'gemma-4-E2B-it.litertlm';
  static const llmDisplayName = 'Gemma 4 E2B';
  static const llmSize = '2.6 GB';

  /// `ModelType.gemma4` is **not** interchangeable with `gemmaIt`. It sends
  /// tool declarations through Gemma 4's own chat template, so the model
  /// replies with native tool calls that the plugin parses into a
  /// [FunctionCallResponse]. `gemmaIt` is the setting for older Gemma chat
  /// models: with it, tools are written into the prompt as plain text instead.
  /// It doesn't change which model runs; the file at [llmUrl] does that.
  static const llmModelType = ModelType.gemma4;

  /// `ModelFileType` selects the *engine* and is never inferred from the file
  /// name. `installModel` defaults it to `.task`, the MediaPipe format, so
  /// leaving it out means this `.litertlm` file won't load.
  static const llmFileType = ModelFileType.litertlm;

  /// Context window (input + history + reply), not the reply length.
  static const llmMaxTokens = 4096;

  // --- Sampling -----------------------------------------------------------
  // Google's published defaults for Gemma 4 are temperature 1.0 / topK 64 /
  // topP 0.95, and those are what we ran first. They are tuned for
  // expressiveness, and on a 2B multilingual model that width has a specific
  // failure mode: CODE SWITCHING. The vocabulary holds tokens for the same
  // concept in many languages, and at temperature 1.0 with 64 candidates in
  // play, a non-English token can simply outrank the English one mid-sentence
  // — producing things like "Here's a thinking プロセス for planning...".
  //
  // Narrowing the distribution makes the model pick the likeliest token far
  // more often, which in an English conversation means the English one. The
  // cost is slightly less varied phrasing. For a live demo that is a good
  // trade; for a creative-writing app it would not be.
  //
  // This reduces code switching, it does not eliminate it — it is model
  // behaviour, not a setting. The system instructions pin the language too,
  // and the two together are what actually make it rare.
  static const llmTemperature = 0.7;
  static const llmTopK = 40;
  static const llmTopP = 0.9;

  /// A short clause appended to every system instruction.
  ///
  /// Pinning the language in the prompt as well as in the sampler matters
  /// because reasoning is generated in the same stream as the answer — so it
  /// drifts in the same way, and the user sees it.
  static const languagePin =
      'Always write in English, including any reasoning. Never substitute '
      'words from other languages or scripts.';

  // Voice replies get tighter sampling still. They are one or two short
  // factual sentences, so varied phrasing buys nothing — and a code-switched
  // token costs more here than on screen, because an English synthesizer
  // cannot pronounce it at all. Lower temperature makes the likeliest token
  // win more often, which in an English context means the English one.
  static const voiceTemperature = 0.3;
  static const voiceTopK = 20;
  static const voiceTopP = 0.85;

  /// Formatting rules for anything a person reads on screen.
  ///
  /// Small models reach for LaTeX constantly, and theirs is frequently
  /// malformed — unbalanced braces, stray backslashes, occasionally a
  /// non-Latin token spliced into a command. The renderer now handles LaTeX
  /// and falls back gracefully, but the best outcome is for the model not to
  /// reach for it in the first place: plain arithmetic is easier to read on a
  /// projector anyway.
  static const readableOutputPin =
      'Write mathematics in plain text, for example "MD = 4.5 years" or '
      '"price change = -0.21%". Do not use LaTeX, dollar-sign math, or '
      'backslash commands. Use short paragraphs and simple bullet lists.';

  // --- Speech-to-text -----------------------------------------------------
  // Whisper Tiny, 30-second window, 151 MB.
  //
  // We started on Moonshine Tiny (109 MB) — but read its filename:
  // `moonshine_tiny_5s_f32.tflite`. It is a fixed FIVE SECOND graph, so
  // anything longer is silently truncated and the end of your sentence just
  // disappears. Whisper Tiny's graph is 30s, which is what makes a
  // conversational turn possible at all.
  //
  // Whisper is also multilingual, and its output language is one token in the
  // decoder's seed prompt — see [sttLanguage].
  static const sttModelUrl =
      'https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_f32.tflite';
  static const sttTokenizerUrl =
      'https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json';
  static const sttModelType = SttModelType.whisper;
  static const sttDisplayName = 'Whisper Tiny';
  static const sttSize = '151 MB';

  /// Whisper's output language, pinned explicitly.
  ///
  /// This controls what the model WRITES, not what it hears: left to drift it
  /// can transcribe English audio into another language, or translate. Passing
  /// it to `getActiveStt(language:)` (new in flutter_gemma 1.8.0) is a
  /// per-call knob — changing it never reloads the model.
  static const sttLanguage = 'en';

  /// The recording cap, kept under Whisper's 30s graph with headroom for the
  /// resampler. Never set this above the window the chosen STT graph was
  /// exported with.
  static const maxRecordingSeconds = 25;

  // --- Text-to-speech -----------------------------------------------------
  // Inflect-Nano-v2, 24000 Hz, ~8 MB of its own weights.
  //
  // We shipped Matcha first: Inflect's speech was unintelligible back then,
  // and Matcha was the documented, better-trodden path. flutter_edge_ai_speech
  // 0.5.2 fixed Inflect ("the encoder now gets the blank tokens it was
  // trained with"), and on this machine the difference is the whole voice
  // demo: synthesizing one 4.8-second sentence took Matcha 15.8 s (0.3x
  // real-time) and Inflect 0.6 s (7.2x real-time), with both samples
  // transcribed back word-perfect by Whisper.
  //
  // Inflect is English-only, which is what the voice loop pins anyway, and it
  // reuses Matcha's four G2P (pronunciation) files — the installer fetches
  // those from the Matcha repo, so only the two Inflect graphs are new.
  static const ttsBaseUrl =
      'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/';
  static const ttsModelType = TtsModelType.inflect;
  static const ttsDisplayName = 'Inflect-Nano';
  static const ttsSize = '35 MB';
}
