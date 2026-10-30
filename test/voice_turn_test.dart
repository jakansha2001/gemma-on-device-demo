import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_vision_demo/gemma/voice_turn.dart';

/// End-to-end tests for the voice pipeline with fake models.
///
/// The pipeline runs three concurrent things — generation, synthesis and
/// playback — feeding one event stream. That is exactly the shape that hangs
/// silently when a controller is never closed, so every test here asserts the
/// stream actually TERMINATES, not just what it emitted.
void main() {
  final pcm = Uint8List(3200);

  /// Builds a turn whose behaviour each test can steer.
  ({VoiceTurn turn, List<String> spokenAloud, List<String> synthesized}) build({
    String transcript = 'plan a trip',
    List<String> tokens = const ['Hello there. ', 'Second sentence here.'],
    Future<String> Function(Uint8List)? transcribeOverride,
    Stream<String> Function(String)? respondOverride,
    Stream<String> Function(Uint8List)? respondToAudio,
    Future<Uint8List> Function(String)? synthesizeOverride,
    Duration playbackDuration = Duration.zero,
  }) {
    final spokenAloud = <String>[];
    final synthesized = <String>[];

    final turn = VoiceTurn(
      respondToAudio: respondToAudio,
      transcribe: transcribeOverride ?? (_) async => transcript,
      respond:
          respondOverride ??
          (prompt) async* {
            for (final t in tokens) {
              await Future<void>.delayed(Duration.zero);
              yield t;
            }
          },
      synthesize:
          synthesizeOverride ??
          (text) async {
            synthesized.add(text);
            return Uint8List(64);
          },
      synthesizerSampleRate: 22050,
      prepareClip: (audio, rate) async => audio,
      playClip: (_) async {
        if (playbackDuration > Duration.zero) {
          await Future<void>.delayed(playbackDuration);
        }
        spokenAloud.add('played');
      },
      stopPlayback: () async {},
    );
    return (turn: turn, spokenAloud: spokenAloud, synthesized: synthesized);
  }

  /// Drain with a timeout — a pipeline that never closes its controller hangs
  /// forever, and a hanging test is indistinguishable from a slow one.
  Future<List<VoiceTurnEvent>> drain(Stream<VoiceTurnEvent> stream) =>
      stream.toList().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('run() never completed'),
      );

  group('happy path', () {
    test('completes, and ends in the done phase', () async {
      final f = build();
      final events = await drain(f.turn.run(pcm));

      expect(events, isNotEmpty);
      expect(
        events.last,
        isA<VoicePhaseChanged>().having(
          (e) => e.phase,
          'phase',
          VoicePhase.done,
        ),
      );
    });

    test('emits the transcript before any reply text', () async {
      final f = build();
      final events = await drain(f.turn.run(pcm));

      final transcriptAt = events.indexWhere((e) => e is VoiceTranscript);
      final firstReplyAt = events.indexWhere((e) => e is VoiceReplyText);
      expect(transcriptAt, isNonNegative);
      expect(firstReplyAt, greaterThan(transcriptAt));
    });

    test('speaks every sentence, in order', () async {
      final f = build();
      await drain(f.turn.run(pcm));

      expect(f.synthesized, ['Hello there.', 'Second sentence here.']);
      expect(f.spokenAloud, hasLength(2));
    });

    test('reports spoken text trailing the generated text', () async {
      final f = build();
      final events = await drain(f.turn.run(pcm));

      final spoken = events.whereType<VoiceSpokenText>().toList();
      expect(spoken, isNotEmpty);
      expect(spoken.last.spokenSoFar, contains('Second sentence'));
    });

    test('starts speaking before generation has finished', () async {
      // The entire reason this class exists. With batch TTS the first audio
      // would only come after the last token.
      final generated = <String>[];
      final firstSynthesisAfter = Completer<int>();

      final f = build(
        respondOverride: (_) async* {
          for (final t in [
            'First sentence here. ',
            'a ',
            'b ',
            'c ',
            'd ',
            'e ',
            'Last one.',
          ]) {
            generated.add(t);
            await Future<void>.delayed(const Duration(milliseconds: 5));
            yield t;
          }
        },
        synthesizeOverride: (text) async {
          if (!firstSynthesisAfter.isCompleted) {
            firstSynthesisAfter.complete(generated.length);
          }
          return Uint8List(64);
        },
      );
      await drain(f.turn.run(pcm));

      // Synthesis began while tokens were still arriving.
      expect(await firstSynthesisAfter.future, lessThan(7));
    });
  });

  group('no dead air between sentences', () {
    test('synthesizes the next sentence WHILE the current one plays', () async {
      // The regression this guards: an earlier version played each sentence
      // to completion before starting the next synthesis, so every sentence
      // boundary had a silent gap as long as the synthesis took.
      final timeline = <String>[];

      final turn = VoiceTurn(
        // Must be long enough to clear the noise filter.
        transcribe: (_) async => 'tell me a story',
        respond: (_) async* {
          yield 'First sentence here. ';
          yield 'Second sentence here. ';
          yield 'Third sentence here.';
        },
        synthesize: (text) async {
          final tag = text.split(' ').first;
          timeline.add('synth-start:$tag');
          await Future<void>.delayed(const Duration(milliseconds: 60));
          timeline.add('synth-end:$tag');
          return Uint8List(64);
        },
        synthesizerSampleRate: 22050,
        prepareClip: (audio, _) async => audio,
        playClip: (_) async {
          timeline.add('play-start');
          await Future<void>.delayed(const Duration(milliseconds: 60));
          timeline.add('play-end');
        },
        stopPlayback: () async {},
      );

      await turn.run(pcm).toList().timeout(const Duration(seconds: 5));

      // The second sentence must begin synthesizing before the first one has
      // finished playing. If it does not, the user hears a gap.
      final secondSynthStart = timeline.indexOf('synth-start:Second');
      final firstPlayEnd = timeline.indexOf('play-end');
      expect(secondSynthStart, isNonNegative);
      expect(
        secondSynthStart,
        lessThan(firstPlayEnd),
        reason:
            'synthesis of sentence 2 must overlap playback of sentence 1\n'
            'timeline: $timeline',
      );
    });

    test('prepares the next clip while the current one plays', () async {
      // Decoding used to happen inside playback, putting its cost straight
      // into the gap between sentences.
      final timeline = <String>[];
      final turn = VoiceTurn(
        transcribe: (_) async => 'tell me a story',
        respond: (_) async* {
          yield 'First sentence here. ';
          yield 'Second sentence here.';
        },
        synthesize: (_) async => Uint8List(64),
        synthesizerSampleRate: 22050,
        prepareClip: (audio, _) async {
          timeline.add('prepare-start');
          await Future<void>.delayed(const Duration(milliseconds: 40));
          timeline.add('prepare-end');
          return audio;
        },
        playClip: (_) async {
          timeline.add('play-start');
          await Future<void>.delayed(const Duration(milliseconds: 60));
          timeline.add('play-end');
        },
        stopPlayback: () async {},
      );

      await turn.run(pcm).toList().timeout(const Duration(seconds: 5));

      // The SECOND prepare must begin before the FIRST playback ends.
      final secondPrepare = timeline.indexOf('prepare-start', 1);
      final firstPlayEnd = timeline.indexOf('play-end');
      expect(secondPrepare, isNonNegative);
      expect(
        secondPrepare,
        lessThan(firstPlayEnd),
        reason: 'clip 2 must be prepared during clip 1\ntimeline: $timeline',
      );
    });

    test('total time reflects overlap, not serialised work', () async {
      // 4 sentences x (60ms synth + 60ms play). Serialised that is ~480ms;
      // overlapped it is ~60ms of lead-in plus 4 x 60ms of playback = ~300ms.
      final sw = Stopwatch()..start();
      final f = build(
        tokens: const [
          'Sentence one here. ',
          'Sentence two here. ',
          'Sentence three here. ',
          'Sentence four here.',
        ],
        synthesizeOverride: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return Uint8List(64);
        },
        playbackDuration: const Duration(milliseconds: 60),
      );
      await drain(f.turn.run(pcm));
      sw.stop();

      expect(
        sw.elapsedMilliseconds,
        lessThan(430),
        reason:
            'took ${sw.elapsedMilliseconds}ms — synthesis is not '
            'overlapping playback',
      );
    });
  });

  group('nothing intelligible was heard', () {
    test('a blank transcript never reaches the model', () async {
      var modelCalled = false;
      final f = build(
        transcript: '   ',
        respondOverride: (_) {
          modelCalled = true;
          return const Stream<String>.empty();
        },
      );
      final events = await drain(f.turn.run(pcm));

      expect(events.whereType<VoiceHeardNothing>(), hasLength(1));
      expect(modelCalled, isFalse);
    });

    test('Whisper silence hallucinations are treated as noise', () async {
      // These are what a hands-free loop used to talk to itself about.
      for (final noise in [
        '[BLANK_AUDIO]',
        'you',
        'Thank you.',
        '...',
        '(silence)',
        'Bye',
      ]) {
        expect(VoiceTurn.isNoise(noise), isTrue, reason: noise);
      }
    });

    test('real speech is not treated as noise', () async {
      for (final real in [
        'plan a trip to Jaipur',
        'what time is it',
        'add buy milk',
        'yes',
      ]) {
        expect(VoiceTurn.isNoise(real), isFalse, reason: real);
      }
    });
  });

  group('failures must still terminate the stream', () {
    test('a transcription failure reports and ends', () async {
      final f = build(
        transcribeOverride: (_) async => throw StateError('stt exploded'),
      );
      final events = await drain(f.turn.run(pcm));
      expect(events.whereType<VoiceTurnFailed>(), hasLength(1));
    });

    test('a generation failure reports and ends', () async {
      final f = build(
        respondOverride: (_) async* {
          yield 'Partial. ';
          throw StateError('llm exploded');
        },
      );
      final events = await drain(f.turn.run(pcm));
      expect(events.whereType<VoiceTurnFailed>(), hasLength(1));
      // The last phase still arrives, so the UI leaves its busy state.
      expect(events.last, isA<VoicePhaseChanged>());
    });

    test('a synthesis failure skips that sentence but finishes', () async {
      final f = build(
        synthesizeOverride: (text) async => throw StateError('tts exploded'),
      );
      final events = await drain(f.turn.run(pcm));
      expect(f.spokenAloud, isEmpty);
      expect(
        events.last,
        isA<VoicePhaseChanged>().having(
          (e) => e.phase,
          'phase',
          VoicePhase.done,
        ),
      );
    });

    test('a model that says nothing still terminates', () async {
      final f = build(respondOverride: (_) => const Stream<String>.empty());
      final events = await drain(f.turn.run(pcm));
      expect(events.last, isA<VoicePhaseChanged>());
    });
  });

  group('cancellation', () {
    test('a cancelled turn does not poison the next one', () async {
      // Regression: _cancelled was never reset, so one Stop press left the
      // instance permanently dead and every later turn silently did nothing.
      // Full-length sentences: the chunker merges anything under its
      // minimum length, so "One." would not be a chunk of its own.
      final f = build(
        tokens: const [
          'First sentence here. ',
          'Second sentence here. ',
          'Third sentence here.',
        ],
        playbackDuration: const Duration(milliseconds: 20),
      );

      final firstSub = f.turn.run(pcm).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await f.turn.cancel();
      await firstSub.cancel();
      // Let the cancelled turn settle: a clip already in playback finishes,
      // which is correct behaviour but would otherwise race this count.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final spokenBefore = f.spokenAloud.length;
      // Cancellation must actually have stopped it short of all three.
      expect(spokenBefore, lessThan(3));

      // The SAME instance must work again.
      final events = await drain(f.turn.run(pcm));
      expect(
        events.last,
        isA<VoicePhaseChanged>().having(
          (e) => e.phase,
          'phase',
          VoicePhase.done,
        ),
      );
      expect(
        f.spokenAloud.length - spokenBefore,
        3,
        reason: 'the second turn must speak all of its sentences',
      );
    });

    test('cancel stops playback and the stream still ends', () async {
      final f = build(
        tokens: const ['One. ', 'Two. ', 'Three. ', 'Four. ', 'Five.'],
        playbackDuration: const Duration(milliseconds: 30),
      );
      final collected = <VoiceTurnEvent>[];
      final sub = f.turn.run(pcm).listen(collected.add);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      await f.turn.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      // Cancelling must stop it well short of speaking all five.
      expect(f.spokenAloud.length, lessThan(5));
    });
  });

  group('audio straight to the model', () {
    test('skips transcription entirely and still speaks the reply', () async {
      var transcribeCalls = 0;
      final heard = <int>[];

      final h = build(
        transcribeOverride: (_) async {
          transcribeCalls++;
          return 'should never be used';
        },
        respondToAudio: (audio) async* {
          heard.add(audio.length);
          yield 'Heard you. ';
          yield 'All good.';
        },
      );

      final events = await h.turn.run(pcm).toList();

      expect(transcribeCalls, 0, reason: 'Whisper must sit this turn out');
      expect(heard, [pcm.length], reason: 'the model gets the recording');
      expect(
        events.whereType<VoiceTranscript>(),
        isEmpty,
        reason: 'nothing transcribed it, so there is no transcript',
      );
      expect(h.synthesized.join(' '), contains('Heard you'));
      expect(h.spokenAloud, isNotEmpty, reason: 'the reply is spoken aloud');
      expect(events.last, isA<VoicePhaseChanged>());
    });

    test('a failure on the audio route still terminates the stream', () async {
      final h = build(
        respondToAudio: (_) async* {
          throw StateError('model refused the audio');
        },
      );

      final events = await h.turn.run(pcm).toList();

      expect(events.whereType<VoiceTurnFailed>(), hasLength(1));
    });
  });
}
