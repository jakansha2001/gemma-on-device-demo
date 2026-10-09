import 'dart:async';
import 'dart:typed_data';

import 'package:gemma_vision_demo/gemma/model_text.dart';
import 'package:gemma_vision_demo/gemma/sentence_chunker.dart';

/// What a turn is currently doing, for the UI to narrate.
enum VoicePhase { transcribing, thinking, speaking, done }

/// One thing that happened during a turn.
sealed class VoiceTurnEvent {
  const VoiceTurnEvent();
}

class VoicePhaseChanged extends VoiceTurnEvent {
  const VoicePhaseChanged(this.phase);
  final VoicePhase phase;
}

/// What the user said.
class VoiceTranscript extends VoiceTurnEvent {
  const VoiceTranscript(this.text);
  final String text;
}

/// The reply so far, as generated. Runs AHEAD of what has been spoken.
class VoiceReplyText extends VoiceTurnEvent {
  const VoiceReplyText(this.fullText);
  final String fullText;
}

/// A sentence has started playing — the spoken text has caught up to here.
class VoiceSpokenText extends VoiceTurnEvent {
  const VoiceSpokenText(this.spokenSoFar);
  final String spokenSoFar;
}

/// Nothing intelligible was heard. The caller decides whether to re-listen.
class VoiceHeardNothing extends VoiceTurnEvent {
  const VoiceHeardNothing();
}

/// One sentence could not be synthesized. The turn continues — its text is
/// already visible, it simply is not spoken.
class VoiceSynthesisSkipped extends VoiceTurnEvent {
  const VoiceSynthesisSkipped(this.sentence, this.error);
  final String sentence;
  final Object error;
}

class VoiceTurnFailed extends VoiceTurnEvent {
  const VoiceTurnFailed(this.error);
  final Object error;
}

/// Runs one voice turn: transcribe → generate → speak.
///
/// **Why this does not use `VoiceSession`.** flutter_edge_ai_speech ships
/// `VoiceSession.fromChat`, which runs this chain in one call.
/// `SpeechSynthesizer.synthesize` is batch ("full text → full audio", per its
/// own dartdoc), and by default `VoiceSession` speaks once the whole reply is
/// ready, which leaves dead air after the text finishes printing.
/// `VoiceSession.fromChat(..., streamAudio: true)` (flutter_edge_ai_speech 0.4.3+)
/// avoids that by speaking clause by clause. This class was written before that
/// option was noticed; for new code, try `streamAudio: true` first.
///
/// Driving the three models directly lets us cut the reply into sentences as
/// it streams and synthesize each one as it completes, so audio starts after
/// the FIRST sentence. Synthesis of sentence N+1 overlaps playback of
/// sentence N, which is what every production voice assistant does.
///
/// The cost of owning this: barge-in, cancellation and draining are ours to
/// get right. [cancel] is the single lever.
class VoiceTurn {
  VoiceTurn({
    required this.transcribe,
    required this.respond,
    required this.synthesize,
    required this.synthesizerSampleRate,
    required this.prepareClip,
    required this.playClip,
    required this.stopPlayback,
  });

  /// 16 kHz mono PCM in, text out.
  final Future<String> Function(Uint8List pcm) transcribe;

  /// Send [prompt] to the model and stream back its reply, token by token.
  final Stream<String> Function(String prompt) respond;

  /// One sentence of text in, PCM out.
  final Future<Uint8List> Function(String text) synthesize;

  final int synthesizerSampleRate;

  /// Load [pcm] into a player and complete when it is ready to start.
  ///
  /// Separate from [playClip] on purpose: writing the WAV and decoding it
  /// costs real time, and doing it inside playback would put that cost in the
  /// gap between sentences. Here it happens on the producer side, overlapping
  /// the previous sentence's playback.
  final Future<Object> Function(Uint8List pcm, int sampleRate) prepareClip;

  /// Play a prepared clip; completes when playback finishes. This is what
  /// paces the whole turn.
  final Future<void> Function(Object clip) playClip;

  final Future<void> Function() stopPlayback;

  /// The in-flight run, if any. Cancellation is scoped to ONE run.
  ///
  /// A single instance-wide bool was wrong in both directions. Never resetting
  /// it meant one Stop press poisoned the object permanently — every later
  /// turn transcribed, saw the flag and returned silently, so the whole voice
  /// loop appeared dead. Resetting it on each run was worse: it un-cancelled a
  /// previous turn that was still draining, which then carried on speaking
  /// over the new one. A token per run is the only thing that gets both right.
  _RunToken? _current;

  /// Whisper emits these for silence or noise. Sending one to the LLM is what
  /// makes a hands-free loop talk to itself forever: it "hears" nothing,
  /// answers anyway, and the reply re-triggers the next turn.
  static final _noiseTranscripts = {
    '',
    'you',
    'thank you',
    'thanks for watching',
    'bye',
    '[blank_audio]',
    '(blank_audio)',
    'blank audio',
    '[silence]',
    '(silence)',
    '[music]',
    '(music)',
    '[noise]',
    '.',
    '...',
  };

  static bool isNoise(String transcript) {
    var t = transcript.toLowerCase().trim();
    // Drop surrounding punctuation so "Thank you." matches "thank you".
    t = t.replaceAll(RegExp(r'^[^a-z\[(]+|[^a-z\])]+$'), '').trim();
    if (t.isEmpty) return true;
    if (_noiseTranscripts.contains(t)) return true;
    // Fewer than three letters is far more often a hallucination than speech.
    return t.replaceAll(RegExp(r'[^a-z]'), '').length < 3;
  }

  /// Stop the current run as soon as possible: skip pending synthesis and cut
  /// playback. Has no effect on any run started afterwards.
  Future<void> cancel() async {
    _current?.cancelled = true;
    await stopPlayback();
  }

  Stream<VoiceTurnEvent> run(Uint8List pcm16kMono) async* {
    final token = _RunToken();
    _current = token;

    // --- 1. Transcribe ------------------------------------------------
    yield const VoicePhaseChanged(VoicePhase.transcribing);
    String transcript;
    try {
      transcript = await transcribe(pcm16kMono);
    } catch (e) {
      yield VoiceTurnFailed(e);
      return;
    }
    if (token.cancelled) return;

    if (isNoise(transcript)) {
      // Do NOT hand this to the model — see _noiseTranscripts.
      yield const VoiceHeardNothing();
      return;
    }
    yield VoiceTranscript(transcript.trim());

    // --- 2. Generate and speak, concurrently --------------------------
    yield const VoicePhaseChanged(VoicePhase.thinking);

    // Generation and speech both push into one controller, which this
    // generator drains. The pipeline owns ALL its own error handling and
    // adds any failure as an event BEFORE the controller is closed — an
    // earlier version closed the controller first and then tried to add the
    // error, which threw "Cannot add event after closing" and swallowed it.
    final events = StreamController<VoiceTurnEvent>();
    final pipeline = _pipeline(transcript, events, token);
    unawaited(
      pipeline.whenComplete(() {
        if (!events.isClosed) events.close();
      }),
    );

    yield* events.stream;
    yield const VoicePhaseChanged(VoicePhase.done);
  }

  /// Stream the reply, cutting it into sentences and speaking each as it
  /// completes. Never throws: failures become [VoiceTurnFailed] events.
  Future<void> _pipeline(
    String transcript,
    StreamController<VoiceTurnEvent> events,
    _RunToken token,
  ) async {
    final chunker = SentenceChunker();
    final sentences = StreamController<String>();
    final spoken = StringBuffer();

    // Started before generation so the first sentence is picked up the
    // instant it exists.
    final speaking = _speakWorker(sentences.stream, spoken, events, token);

    try {
      final full = StringBuffer();
      await for (final piece in respond(transcript)) {
        if (token.cancelled) break;
        full.write(piece);
        if (!events.isClosed) {
          events.add(
            VoiceReplyText(
              ModelText.sanitize(full.toString(), streaming: true),
            ),
          );
        }
        for (final sentence in chunker.add(piece)) {
          if (!sentences.isClosed) sentences.add(sentence);
        }
      }
      final tail = chunker.flush();
      if (tail != null && !token.cancelled && !sentences.isClosed) {
        sentences.add(tail);
      }
    } catch (e) {
      if (!events.isClosed) events.add(VoiceTurnFailed(e));
    } finally {
      // Closing the sentence stream is what lets the speak worker finish.
      if (!sentences.isClosed) await sentences.close();
      try {
        await speaking;
      } catch (e) {
        if (!events.isClosed) events.add(VoiceTurnFailed(e));
      }
    }
  }

  /// Speak each sentence as it arrives, synthesizing the NEXT one while the
  /// current one plays.
  ///
  /// This is a producer/consumer pair on purpose. The obvious sequential
  /// shape — synthesize, play, synthesize, play — leaves a silent gap between
  /// every sentence exactly as long as it takes to synthesize the next one,
  /// because nothing starts generating audio until playback has finished.
  /// Splitting the two means the synthesizer is working on sentence N+1
  /// throughout the playback of sentence N, so by the time N finishes, N+1 is
  /// usually already waiting. Only the FIRST sentence pays synthesis latency.
  ///
  /// Synthesis itself stays strictly sequential: it is CPU-bound, and running
  /// several at once on a phone would slow every one of them down (and
  /// compete with the LLM still generating tokens).
  Future<void> _speakWorker(
    Stream<String> sentences,
    StringBuffer spoken,
    StreamController<VoiceTurnEvent> events,
    _RunToken token,
  ) async {
    final ready = StreamController<({Object clip, String text})>();

    // Producer: synthesize, one at a time, as fast as sentences arrive.
    final producing = () async {
      try {
        await for (final sentence in sentences) {
          if (token.cancelled) continue; // drain the stream without working
          try {
            // The synthesizer is English-only; see ModelText.forSpeech. The
            // on-screen text is untouched.
            final speakable = ModelText.forSpeech(sentence);
            if (speakable.isEmpty) continue;
            final pcm = await synthesize(speakable);
            if (pcm.isEmpty || token.cancelled) continue;
            // Prepared here, not at playback time — see [prepareClip].
            final clip = await prepareClip(pcm, synthesizerSampleRate);
            if (!token.cancelled) ready.add((clip: clip, text: sentence));
          } catch (e) {
            // A sentence that will not synthesize must not kill the turn —
            // its text is already on screen. Skip it and keep going.
            if (!events.isClosed) {
              events.add(VoiceSynthesisSkipped(sentence, e));
            }
          }
        }
      } finally {
        await ready.close();
      }
    }();

    // Consumer: play in order, which is what paces the whole turn.
    final playing = () async {
      await for (final clip in ready.stream) {
        if (token.cancelled) continue;
        spoken.write(spoken.isEmpty ? clip.text : ' ${clip.text}');
        if (!events.isClosed) {
          events
            ..add(const VoicePhaseChanged(VoicePhase.speaking))
            ..add(VoiceSpokenText(spoken.toString()));
        }
        await playClip(clip.clip);
      }
    }();

    await Future.wait([producing, playing]);
  }
}

/// Identity for one run, so [VoiceTurn.cancel] affects exactly that run.
class _RunToken {
  bool cancelled = false;
}
