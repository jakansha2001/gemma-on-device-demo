import 'dart:async';
import 'dart:collection';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:gemma_vision_demo/gemma/gemma_failure.dart';
import 'package:gemma_vision_demo/gemma/gemma_service.dart';
import 'package:gemma_vision_demo/gemma/model_catalog.dart';
import 'package:gemma_vision_demo/gemma/voice_activity_detector.dart';
import 'package:gemma_vision_demo/gemma/voice_turn.dart';
import 'package:gemma_vision_demo/theme.dart';
import 'package:gemma_vision_demo/utils/audio_converter.dart';
import 'package:gemma_vision_demo/widgets/status_view.dart';
import 'package:gemma_vision_demo/widgets/voice_controls.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// Push-to-talk speech → LLM → speech, entirely on-device.
///
/// [VoiceSession] (flutter_edge_ai_speech) chains the three models into a single
/// `runTurn` that streams [VoiceEvent]s. It owns no microphone and no player,
/// so this screen supplies both: `record` captures 16 kHz mono WAV, and
/// `just_audio` plays the synthesized reply back.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

/// Where a turn currently is, so the UI can narrate the pipeline.
///
/// Order matters: [_PipelineBar] treats a lower index as an earlier step.
/// [armed] sits between idle and recording — hands-free, mic open, waiting for
/// you to start speaking.
enum VoiceStage { idle, armed, recording, transcribing, thinking, speaking }

/// How a turn is started.
enum VoiceMode {
  /// Tap to start, tap to stop. Nothing can trigger it by accident, which is
  /// what you want in a room full of people.
  pushToTalk,

  /// The mic stays open; the turn starts when you speak and ends when you
  /// stop. More natural, but background noise can trigger it.
  handsFree;

  String get label =>
      this == VoiceMode.pushToTalk ? 'Push to talk' : 'Hands-free';
}

class _VoiceScreenState extends State<VoiceScreen> {
  final _recorder = AudioRecorder();

  /// A small pool, so one clip can load while another plays and decoding
  /// never lands in the gap between sentences.
  ///
  /// Borrowed and returned rather than used round-robin. Alternating by index
  /// looks equivalent but is not: the producer runs ahead of playback, so it
  /// would eventually reuse a player that is still mid-sentence and cut it
  /// off. Borrowing makes a busy player simply unavailable, which also bounds
  /// how far ahead the producer can get.
  final _players = [AudioPlayer(), AudioPlayer(), AudioPlayer()];
  late final Queue<AudioPlayer> _freePlayers = Queue.of(_players);
  final Queue<Completer<AudioPlayer>> _playerWaiters = Queue();

  Future<AudioPlayer> _acquirePlayer() {
    if (_freePlayers.isNotEmpty) {
      return Future.value(_freePlayers.removeFirst());
    }
    final waiter = Completer<AudioPlayer>();
    _playerWaiters.add(waiter);
    return waiter.future;
  }

  void _releasePlayer(AudioPlayer player) {
    if (_playerWaiters.isNotEmpty) {
      _playerWaiters.removeFirst().complete(player);
    } else if (!_freePlayers.contains(player)) {
      _freePlayers.add(player);
    }
  }

  /// Hand every player back, and unblock anything waiting for one. Without
  /// this, cancelling a turn mid-playback leaves a borrowed player out and a
  /// producer parked on a future that never completes.
  void _resetPlayerPool() {
    while (_playerWaiters.isNotEmpty) {
      final waiter = _playerWaiters.removeFirst();
      if (!waiter.isCompleted) waiter.complete(_players.first);
    }
    _freePlayers
      ..clear()
      ..addAll(_players);
  }

  SpeechRecognizer? _recognizer;
  SpeechSynthesizer? _synth;
  InferenceChat? _chat;
  VoiceTurn? _turn;

  bool _loading = true;
  GemmaFailure? _failure;
  String _setupStage = 'Preparing';
  int? _setupPercent;

  VoiceMode _mode = VoiceMode.pushToTalk;
  VoiceStage _stage = VoiceStage.idle;
  Duration _elapsed = Duration.zero;
  Timer? _timer;

  // --- Voice activity detection (hands-free only) ----------------------
  // flutter_edge_ai ships no VAD, so we derive one from the recorder's own
  // amplitude stream. `Amplitude.current` is dBFS: 0 is full scale and
  // quiet rooms sit near -50. These two numbers are the whole heuristic and
  // are the first thing to tune if it misfires in a particular room.
  // Voice activity detection lives in its own tested class — see
  // [VoiceActivityDetector]. Two wrong versions of this shipped while the
  // logic was inline here and untestable.
  final _vad = VoiceActivityDetector();

  /// How long the mic may stay open hearing nothing before we give up.
  /// Without this, a trigger level that is never crossed leaves hands-free
  /// armed forever with no way to end the turn.
  static const _armedTimeout = Duration(seconds: 15);

  Duration _armedFor = Duration.zero;

  /// Raw 16 kHz mono PCM, accumulated as the recorder streams it.
  ///
  /// We stream rather than record to a file because `AudioRecorder.stop()`
  /// never completes on macOS — it hangs, taking the whole screen with it.
  /// Holding the samples ourselves means stopping is just cancelling a
  /// subscription, and the audio is already in hand either way.
  final _capture = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _captureSub;

  /// Audio waiting to be measured, so the detector gets ONE level per
  /// [_vadFrame] rather than one per stream chunk.
  ///
  /// This matters more than it looks. The recorder emits chunks every few
  /// milliseconds; the detector was designed around a 150 ms sample and its
  /// timings are all expressed in those terms. Feeding it raw chunks made
  /// every frame count fifteen times finer, and a level measured over 10 ms of
  /// speech swings wildly — a vowel and a stop consonant differ by 30 dB.
  /// Averaging over 150 ms is a far steadier signal, and restores the cadence
  /// the thresholds were tuned for.
  final _vadBuffer = BytesBuilder(copy: false);

  /// One detector sample per this much audio. Matches
  /// [VoiceActivityDetector.pollInterval], which its timings assume.
  static const _vadFrameMs = 150;
  static const _vadFrameBytes = 16000 * 2 * _vadFrameMs ~/ 1000;

  /// Fires if a turn sits in a model-bound phase without progress. Nothing
  /// else can rescue a stalled turn: the stage would stay non-idle forever,
  /// and the screen would look dead.
  Timer? _watchdog;
  static const _turnStallTimeout = Duration(seconds: 90);
  double _level = -60;

  /// How far through the end-of-turn pause we are, mirrored from the detector
  /// so the UI can show it filling. A pause that is not registering should be
  /// visible, not something the user has to infer from nothing happening.
  double _quietProgress = 0;
  // Tied to the STT graph's window — see Models.maxRecordingSeconds.
  static const _maxRecording = Duration(seconds: Models.maxRecordingSeconds);

  String? _transcript;

  /// Everything generated so far. Runs ahead of [_spoken].
  String _reply = '';

  /// The portion that has actually been read aloud. Rendering the two
  /// differently is what stops the text looking like it "finished" long
  /// before the audio did.
  String _spoken = '';
  String? _turnError;

  /// Guards the async gap between tapping and `_stage` actually flipping — a
  /// fast double-tap would otherwise start two recordings.
  bool _starting = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _failure = null;
      _setupPercent = null;
    });

    // Promoted to fields only at the end, so anything already opened must be
    // closed by hand if we bail out early — otherwise a failed init leaks a
    // recognizer/synth/chat on every retry.
    SpeechRecognizer? recognizer;
    SpeechSynthesizer? synth;
    InferenceChat? chat;
    Future<void> closePartial() async {
      await recognizer?.close();
      await synth?.close();
      await chat?.close();
    }

    try {
      // --- 1. Speech-to-text. Needs two files: model + tokenizer. ---------
      _setStage('Downloading ${Models.sttDisplayName} · ${Models.sttSize}');
      await FlutterEdgeAi.installStt()
          .modelFromNetwork(Models.sttModelUrl)
          .tokenizerFromNetwork(Models.sttTokenizerUrl)
          .ofType(Models.sttModelType)
          .withModelProgress(_setPercent)
          .withTokenizerProgress(_setPercent)
          .install();
      if (_disposed) {
        await closePartial();
        return;
      }
      // Pin the output language. Whisper is multilingual and will otherwise
      // drift — it can render English speech into another language. This is
      // a per-call knob: it never reloads the model.
      recognizer = await FlutterEdgeAi.getActiveStt(
        language: Models.sttLanguage,
      );

      // --- 2. Text-to-speech. One base URL; the bundle is fetched from it. -
      _setStage('Downloading ${Models.ttsDisplayName} · ${Models.ttsSize}');
      await FlutterEdgeAi.installTts()
          .fromNetwork(Models.ttsBaseUrl)
          .ofType(Models.ttsModelType)
          .withProgress(_setPercent)
          .install();
      if (_disposed) {
        await closePartial();
        return;
      }
      synth = await FlutterEdgeAi.getActiveTts();

      // --- 3. The LLM in the middle. -------------------------------------
      _setStage('Loading ${Models.llmDisplayName}');
      chat = await GemmaService.instance.openChat(
        tools: const [],
        // See Models.voiceTemperature: a code-switched token is worse here
        // than on screen, because the synthesizer cannot say it.
        temperature: Models.voiceTemperature,
        topK: Models.voiceTopK,
        topP: Models.voiceTopP,
        // The reply is spoken, so cap it hard — a 400-token answer would take
        // most of a minute to read out.
        maxOutputTokens: 110,
        systemInstruction:
            'Your reply will be read aloud by an English speech '
            'synthesizer. Answer in one or two short, plain sentences. '
            'No lists, no markdown, no emoji, no special characters. '
            '${Models.languagePin}',
      );
      if (_disposed) {
        await closePartial();
        return;
      }

      // Driving the three models ourselves rather than VoiceSession. See the
      // VoiceTurn class doc: VoiceSession(streamAudio: true) now covers the
      // sentence-by-sentence speaking this does.
      final recognizerRef = recognizer;
      final synthRef = synth;
      final chatRef = chat;
      final turn = VoiceTurn(
        transcribe: (pcm) =>
            recognizerRef.transcribe(pcm, language: Models.sttLanguage),
        respond: (prompt) async* {
          await chatRef.addQueryChunk(Message.text(text: prompt, isUser: true));
          await for (final r in chatRef.generateChatResponseAsync()) {
            // Only the text channel is spoken. Thinking and tool calls are
            // not part of a voice turn.
            if (r is TextResponse) yield r.token;
          }
        },
        synthesize: synthRef.synthesize,
        synthesizerSampleRate: synthRef.sampleRate,
        prepareClip: _prepareClip,
        playClip: _playClip,
        stopPlayback: _stopAllPlayers,
      );

      if (!mounted) {
        await closePartial();
        return;
      }
      setState(() {
        _recognizer = recognizer;
        _synth = synth;
        _chat = chat;
        _turn = turn;
        _loading = false;
      });
    } catch (e) {
      await closePartial();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = GemmaFailure.from(e);
      });
    }
  }

  void _setStage(String label) {
    if (!mounted) return;
    setState(() {
      _setupStage = label;
      _setupPercent = null;
    });
  }

  void _setPercent(int percent) {
    if (!mounted) return;
    setState(() => _setupPercent = percent);
  }

  Future<void> _setMode(VoiceMode mode) async {
    if (_mode == mode) return;
    // Leaving hands-free must close the open mic, or it keeps listening.
    await _stopListening();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _stage = VoiceStage.idle;
      _elapsed = Duration.zero;
    });
    if (mode == VoiceMode.handsFree) await _start(handsFree: true);
  }

  /// Tear down the mic and the amplitude subscription, whatever state we are
  /// in. Safe to call repeatedly.
  Future<void> _stopListening() async {
    _timer?.cancel();
    _timer = null;
    await _captureSub?.cancel();
    _captureSub = null;
    _armedFor = Duration.zero;
    _vad.reset();
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {
      // Nothing useful to do if the recorder is already gone.
    }
  }

  // --- recording ----------------------------------------------------------

  Future<bool> _ensureMicPermission() async {
    // permission_handler covers Android/iOS; on desktop the entitlement does
    // the work and the plugin may throw, so fall back to the recorder's own
    // check rather than blocking the user.
    try {
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          if (!mounted) return false;
          _toast(
            status.isPermanentlyDenied
                ? 'Microphone access is blocked. Enable it in Settings.'
                : 'Microphone permission is required to speak.',
            action: status.isPermanentlyDenied
                ? SnackBarAction(label: 'Settings', onPressed: openAppSettings)
                : null,
          );
          return false;
        }
      }
    } catch (_) {
      // Fall through to the recorder check below.
    }

    try {
      // On macOS this triggers the system permission prompt on first use.
      // A timeout matters: if the prompt never resolves we must not leave
      // `_starting` latched, which would make every later tap a no-op.
      final granted = await _recorder.hasPermission().timeout(
        const Duration(seconds: 20),
        onTimeout: () => false,
      );
      if (!granted) {
        if (mounted) {
          setState(
            () => _turnError =
                'Microphone permission was denied. Allow it in System '
                'Settings → Privacy & Security → Microphone, then try again.',
          );
        }
        return false;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _turnError = 'Could not access the microphone: $e');
      }
      return false;
    }
    return true;
  }

  /// Set the moment the button is pressed, cleared once the recorder is
  /// actually running. Without it, a slow microphone-permission check looks
  /// exactly like a dead button.
  bool _preparing = false;

  Future<void> _toggle() async {
    // Hands-free: the button pauses / resumes listening entirely.
    if (_mode == VoiceMode.handsFree) {
      if (_stage == VoiceStage.armed || _stage == VoiceStage.recording) {
        await _stopListening();
        if (mounted) setState(() => _stage = VoiceStage.idle);
      } else if (_stage == VoiceStage.idle) {
        await _start(handsFree: true);
      }
      return;
    }

    if (_stage == VoiceStage.recording) {
      await _stopAndRun();
      return;
    }
    if (_stage != VoiceStage.idle || _starting) return;
    _starting = true;
    try {
      await _start();
    } finally {
      _starting = false;
    }
  }

  /// Reset everything to a known-good state. Used by the watchdog and by the
  /// button whenever a turn is in progress.
  Future<void> _recoverToIdle({String? reason}) async {
    _watchdog?.cancel();
    _watchdog = null;
    _preparing = false;
    await _turn?.cancel();
    await _stopAllPlayers();
    _resetPlayerPool();
    await _stopListening();
    if (!mounted) return;
    setState(() {
      _stage = VoiceStage.idle;
      if (reason != null) _turnError = reason;
    });
  }

  Future<void> _start({bool handsFree = false}) async {
    if (mounted) setState(() => _preparing = true);
    try {
      if (!await _ensureMicPermission()) return;
    } finally {
      if (mounted) setState(() => _preparing = false);
    }

    try {
      _capture.clear();
      _vadBuffer.clear();
      await _captureSub?.cancel();
      final chunks = await _recorder.startStream(
        const RecordConfig(
          // Raw PCM, not WAV: we want the samples, not a container.
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _captureSub = chunks.listen(
        _onAudioChunk,
        onError: (Object e) {
          if (mounted) {
            setState(() => _turnError = 'Microphone stream failed: $e');
          }
          unawaited(_recoverToIdle());
        },
      );
      if (!mounted) return;
      setState(() {
        // Hands-free opens the mic but does not consider the turn started
        // until it actually hears you.
        _stage = handsFree ? VoiceStage.armed : VoiceStage.recording;
        _elapsed = Duration.zero;
        _transcript = null;
        _reply = '';
        _turnError = null;
        _armedFor = Duration.zero;
      });
      _vad.reset();
      _vadBuffer.clear();
      _quietProgress = 0;

      // Absolute deadline for the capture, independent of the per-second
      // counter. If anything stops that counter advancing, the recording
      // would otherwise never end and the screen would sit in `recording`
      // with no way forward.
      _armWatchdog(
        Duration(seconds: Models.maxRecordingSeconds + 15),
        'Recording did not finish. Tap to try again.',
      );

      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_stage == VoiceStage.recording) {
          setState(() => _elapsed += const Duration(seconds: 1));
          // Hard stop at the STT graph's window. Recording past it does not
          // fail — it silently truncates, which is worse.
          if (_elapsed >= _maxRecording) _stopAndRun();
        } else if (_stage == VoiceStage.armed) {
          _armedFor += const Duration(seconds: 1);
          // Safety net. If the trigger level is wrong for this room, speech
          // is never detected, so nothing else would ever end this turn and
          // hands-free would hang with the mic open.
          if (_armedFor >= _armedTimeout) {
            final diagnostics = _vad.describe();
            unawaited(_stopListening());
            if (mounted) {
              setState(() {
                _stage = VoiceStage.idle;
                // Report the NUMBERS, not just "I could not hear you". If no
                // samples arrived at all, the microphone stream is the
                // problem; if they arrived but stayed below the trigger, the
                // level is.
                _turnError = _vad.sampleCount == 0
                    ? 'No microphone level data arrived, so speech could '
                          'never be detected. Push-to-talk still works.'
                    : 'Did not detect speech in '
                          '${_armedTimeout.inSeconds}s.\n$diagnostics';
              });
            }
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = VoiceStage.idle;
        // Surface it in the panel too — a snackbar is easy to miss, and a
        // button that appears to do nothing is the worst possible outcome.
        _turnError = 'Could not start recording: $e';
      });
    }
  }

  /// Every chunk of microphone audio: keep it, and in hands-free use it to
  /// decide whether speech has started or stopped.
  void _onAudioChunk(Uint8List chunk) {
    if (!mounted || chunk.isEmpty) return;
    _capture.add(chunk);

    if (_mode != VoiceMode.handsFree) return;

    // Accumulate until there is a full frame to measure.
    _vadBuffer.add(chunk);
    if (_vadBuffer.length < _vadFrameBytes) return;

    final frame = _vadBuffer.toBytes();
    _vadBuffer.clear();

    final db = AudioConverter.rmsDbfs(frame);
    final wasSpeaking = _vad.speechStarted;
    _vad.addSample(
      db,
      duration: AudioConverter.pcmDuration(frame, sampleRate: 16000),
    );

    setState(() {
      _level = db;
      _quietProgress = _vad.quietProgress;
      if (_vad.speechStarted && !wasSpeaking) _stage = VoiceStage.recording;
    });

    if (_vad.shouldEndTurn) _stopAndRun();
  }

  Future<void> _stopAndRun() async {
    _timer?.cancel();
    _timer = null;
    // The capture deadline is done with; _runTurn arms its own.
    _watchdog?.cancel();
    _watchdog = null;
    await _captureSub?.cancel();
    _captureSub = null;
    _armedFor = Duration.zero;
    _vad.reset();
    _vadBuffer.clear();
    _quietProgress = 0;

    // Stop the stream first, then take what we captured. `stop()` is fired
    // and NOT awaited: on macOS it never completes, and we already hold every
    // sample, so there is nothing to wait for.
    await _captureSub?.cancel();
    _captureSub = null;
    unawaited(_recorder.stop().catchError((Object _) => null));

    if (!mounted) return;
    setState(() => _stage = VoiceStage.idle);

    final pcm = _capture.toBytes();
    _capture.clear();

    final duration = AudioConverter.pcmDuration(pcm, sampleRate: 16000);
    if (duration < const Duration(milliseconds: 400)) {
      // In hands-free this is usually a door slam, not speech: re-arm
      // silently rather than nagging the user about it.
      if (_mode == VoiceMode.handsFree) {
        await _rearmIfHandsFree();
      } else {
        _toast('That was too short — tap and speak.');
      }
      return;
    }

    await _runTurn(pcm);
  }

  Future<void> _runTurn(Uint8List pcm) async {
    final turn = _turn;
    if (turn == null || _stage != VoiceStage.idle) return;

    setState(() {
      _stage = VoiceStage.transcribing;
      _transcript = null;
      _reply = '';
      _spoken = '';
      _turnError = null;
    });

    var heardNothing = false;
    try {
      _armWatchdog();
      await for (final event in turn.run(pcm)) {
        if (!mounted) return;
        // Any event is progress, so push the deadline out again.
        _armWatchdog();
        switch (event) {
          case VoicePhaseChanged(:final phase):
            setState(() {
              _stage = switch (phase) {
                VoicePhase.transcribing => VoiceStage.transcribing,
                VoicePhase.thinking => VoiceStage.thinking,
                VoicePhase.speaking => VoiceStage.speaking,
                VoicePhase.done => VoiceStage.idle,
              };
            });
          case VoiceTranscript(:final text):
            setState(() => _transcript = text);
          case VoiceReplyText(:final fullText):
            setState(() => _reply = fullText);
          case VoiceSpokenText(:final spokenSoFar):
            setState(() => _spoken = spokenSoFar);
          case VoiceHeardNothing():
            heardNothing = true;
            if (_mode == VoiceMode.pushToTalk) {
              // Push-to-talk has no retry loop, so say so rather than
              // silently returning to idle as if nothing happened.
              _toast('I did not catch that — try speaking a little louder.');
            }
          case VoiceSynthesisSkipped(:final error):
            // The sentence is still on screen and the turn carries on, but
            // say why it went unspoken instead of failing silently.
            _toast('Could not speak part of the reply: $error');
          case VoiceTurnFailed(:final error):
            final f = GemmaFailure.from(error);
            setState(() => _turnError = '${f.title}: ${f.message}');
        }
      }
    } catch (e) {
      if (!mounted) return;
      final f = GemmaFailure.from(e);
      setState(() => _turnError = '${f.title}: ${f.message}');
    } finally {
      _watchdog?.cancel();
      _watchdog = null;
      if (mounted) setState(() => _stage = VoiceStage.idle);
      // The reply has finished playing by the time the stream closes, so this
      // is the point at which it is safe to listen again. We deliberately do
      // NOT keep the mic open during playback: without echo cancellation the
      // speaker talks straight into the microphone and the model answers
      // itself.
      await _rearmIfHandsFree(heardNothing: heardNothing);
    }
  }

  /// Arm a deadline that returns the screen to idle if nothing happens.
  ///
  /// Every long-running state needs one. A stage that can be entered but not
  /// left makes the whole screen look dead, and there is no other mechanism
  /// that would notice.
  void _armWatchdog([Duration? timeout, String? reason]) {
    _watchdog?.cancel();
    _watchdog = Timer(timeout ?? _turnStallTimeout, () {
      if (!mounted) return;
      unawaited(
        _recoverToIdle(
          reason:
              reason ??
              'The turn stopped responding after '
                  '${_turnStallTimeout.inSeconds}s and was cancelled. '
                  'Tap to try again.',
        ),
      );
    });
  }

  /// Consecutive turns where nothing intelligible was heard. Hands-free stops
  /// itself rather than looping forever in a noisy room.
  int _silentTurns = 0;
  static const _maxSilentTurns = 3;

  /// Start the next turn automatically, in hands-free mode only.
  Future<void> _rearmIfHandsFree({bool heardNothing = false}) async {
    if (!mounted || _mode != VoiceMode.handsFree) return;
    if (_stage != VoiceStage.idle) return;

    if (heardNothing) {
      _silentTurns++;
      if (_silentTurns >= _maxSilentTurns) {
        _silentTurns = 0;
        if (mounted) {
          setState(() => _stage = VoiceStage.idle);
          _toast('Stopped listening — I could not hear anything.');
        }
        return;
      }
    } else {
      _silentTurns = 0;
    }

    // Settle before reopening the microphone. Reopening the instant playback
    // finishes lets the tail of the reply — and the room's reverb of it —
    // land in the next capture, which starts a turn the user never spoke.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted || _mode != VoiceMode.handsFree) return;
    if (_stage != VoiceStage.idle) return;
    await _start(handsFree: true);
  }

  /// Monotonic counter so every clip gets its own filename — see below.
  int _clipCounter = 0;

  Future<void> _stopAllPlayers() async {
    for (final player in _players) {
      try {
        await player.stop();
      } catch (_) {
        // Stopping an idle player is not an error worth surfacing.
      }
    }
  }

  /// Write the clip and load it into the next free player.
  ///
  /// Returns the player itself as the opaque handle [VoiceTurn] hands back to
  /// [_playClip].
  Future<Object> _prepareClip(Uint8List pcm, int sampleRate) async {
    final wav = AudioConverter.pcmToWav(pcm, sampleRate: sampleRate);
    final dir = await getTemporaryDirectory();
    // path_provider does not create this folder, and macOS may delete it
    // when disk space runs low. Without it every write fails and the reply
    // is shown but never spoken.
    await dir.create(recursive: true);

    // A UNIQUE path per clip, deliberately. just_audio caches by URI, so
    // reusing one filename meant the second sentence either replayed the
    // first one's audio or returned instantly.
    final file = File('${dir.path}/voice_reply_${_clipCounter++}.wav');
    await file.writeAsBytes(wav);

    // Waits if every player is busy, which is what stops the producer
    // running so far ahead that it reuses a player mid-sentence.
    final player = await _acquirePlayer();
    await player.stop();
    await player.setFilePath(file.path);

    unawaited(file.delete().catchError((Object _) => file));
    return player;
  }

  Future<void> _playClip(Object clip) async {
    if (clip is! AudioPlayer) return;
    try {
      if (mounted) {
        // Completes when playback finishes, which is what paces the turn.
        await clip.play();
      }
    } catch (e) {
      if (mounted) _toast('Could not play the reply aloud: $e');
    } finally {
      _releasePlayer(clip);
    }
  }

  /// Barge-in: stop speaking immediately and abandon the rest of the turn.
  Future<void> _bargeIn() async {
    await _turn?.cancel();
    await _stopAllPlayers();
    if (mounted) setState(() => _stage = VoiceStage.idle);
  }

  /// Always available: stop everything and return to idle, from any state.
  /// Hands-free previously had no way out mid-loop except leaving the screen.
  Future<void> _stopEverything() async {
    _silentTurns = 0;
    await _turn?.cancel();
    await _stopAllPlayers();
    await _stopListening();
    if (mounted) setState(() => _stage = VoiceStage.idle);
  }

  void _toast(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _watchdog?.cancel();
    _captureSub?.cancel();
    _recorder.dispose();
    for (final p in _players) {
      p.dispose();
    }
    _recognizer?.close();
    _synth?.close();
    _chat?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Voice loop', style: AppText.heading),
            Text(
              '${Models.sttDisplayName} → Gemma 4 → ${Models.ttsDisplayName}',
              style: AppText.caption,
            ),
          ],
        ),
        actions: [
          if (!_loading && _failure == null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ModeToggle(
                mode: _mode,
                // Changing mode mid-turn would cut the model off mid-sentence.
                enabled:
                    _stage == VoiceStage.idle ||
                    _stage == VoiceStage.armed ||
                    _stage == VoiceStage.recording,
                onChanged: _setMode,
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? LoadingView(
                title: _setupStage,
                accent: AppColors.voice,
                progress: _setupPercent == null ? null : _setupPercent! / 100,
                subtitle: _setupPercent == null
                    ? 'Three models, all running locally.'
                    : '$_setupPercent%',
              )
            : _failure != null
            ? ErrorView(failure: _failure!, onRetry: _init)
            : _body(),
      ),
    );
  }

  Widget _body() {
    final busy =
        _stage == VoiceStage.transcribing ||
        _stage == VoiceStage.thinking ||
        _stage == VoiceStage.speaking;
    // Padding, not a constrained box: a scroll view inside a narrow box puts
    // its scrollbar in the middle of a wide window.
    final inset = pageInset(
      MediaQuery.sizeOf(context).width,
      medium: 760,
      expanded: 960,
      gutter: 20,
    );
    return Column(
      children: [
        Expanded(
          // Centred in whatever height is left, so a two-line exchange
          // doesn't sit at the top of a full-screen window with a metre of
          // nothing under it.
          child: CentredScrollView(
            padding: EdgeInsets.fromLTRB(inset, 8, inset, 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PipelineBar(stage: _stage),
                Gap.lg,
                if (_transcript == null && _reply.isEmpty && _turnError == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: EmptyView(
                      icon: Icons.mic_none_rounded,
                      accent: AppColors.voice,
                      title: _mode == VoiceMode.handsFree
                          ? 'Just start talking'
                          : 'Tap the mic and talk',
                      subtitle: _mode == VoiceMode.handsFree
                          ? 'The mic is open. It answers when you stop '
                                'speaking, then listens again.'
                          : 'Your voice is transcribed, answered and spoken '
                                'back without a single network call.',
                    ),
                  ),
                if (_transcript != null)
                  VoicePanel(
                    label: 'You said',
                    color: AppColors.voice,
                    child: Text(
                      _transcript!.trim().isEmpty
                          ? "(nothing recognised — try speaking a little louder)"
                          : _transcript!,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 17,
                        height: 1.4,
                      ),
                    ),
                  ),
                if (_reply.isNotEmpty) ...[
                  Gap.md,
                  VoicePanel(
                    label: _stage == VoiceStage.speaking
                        ? 'Gemma is saying'
                        : 'Gemma replied',
                    color: AppColors.accentBright,
                    child: SpokenText(full: _reply, spoken: _spoken),
                  ),
                ],
                if (_turnError != null) ...[
                  Gap.md,
                  VoicePanel(
                    label: 'Something went wrong',
                    color: AppColors.danger,
                    child: Text(
                      _turnError!,
                      style: const TextStyle(
                        color: AppColors.danger,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        MicControl(
          mode: _mode,
          stage: _stage,
          level: _level,
          preparing: _preparing,
          quietProgress: _quietProgress,
          onSensitivityChanged: (db) => setState(() => _vad.thresholdDb = db),
          triggerDb: _vad.triggerDb,
          elapsed: _elapsed,
          maxDuration: _maxRecording,
          // NEVER null. A disabled button is indistinguishable from a broken
          // one: if a turn got stuck in a model-bound phase, `busy` stayed
          // true and every tap silently did nothing. While busy the button
          // cancels instead.
          onTap: busy ? _stopEverything : _toggle,
          onBargeIn: _bargeIn,
          onStop: _stage == VoiceStage.idle ? null : _stopEverything,
        ),
      ],
    );
  }
}
