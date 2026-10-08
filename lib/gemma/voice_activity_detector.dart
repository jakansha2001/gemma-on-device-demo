/// Decides when speech starts and stops, from microphone level samples.
///
/// **A FIXED threshold, deliberately.**
///
/// An earlier version of this learned the room's noise floor and set the bar
/// relative to it. That is the textbook approach and it was a mistake here.
/// The floor has to be learned from quiet audio only — but "quiet" is defined
/// by the bar, and the bar is derived from the floor. That loop has no
/// damping: as the bar rises, more audio qualifies to raise it further, so it
/// ratchets upward on its own and eventually sits above the speaker. Every
/// attempt to break the loop (freezing the floor during speech, excluding
/// loud frames, clamping the range) fixed one symptom and created another.
///
/// A constant cannot drift, cannot chase your voice, and can be reasoned
/// about from the value alone. The trade is that it must be set for the
/// microphone: too low and a fan counts as speech, too high and you have to
/// raise your voice. That is a knob a person can turn in ten seconds, which
/// the adaptive version never was.
///
/// Levels are dBFS, where 0 is full scale. Near a laptop microphone: normal
/// speech lands around -25 to -15, a fan or humming around -45 to -30.
class VoiceActivityDetector {
  VoiceActivityDetector({
    double thresholdDb = defaultThresholdDb,
    // ignore: prefer_initializing_formals — clamped through the setter below.
    this.hysteresisDb = 4.0,
    this.pollInterval = const Duration(milliseconds: 150),
    this.minVoiced = const Duration(milliseconds: 350),
    this.silenceToEnd = const Duration(milliseconds: 2600),
  }) : _thresholdDb = thresholdDb.clamp(minThresholdDb, maxThresholdDb);

  /// Sensible starting point for a laptop microphone.
  static const defaultThresholdDb = -40.0;

  /// The range the in-app sensitivity control can reach.
  static const minThresholdDb = -55.0;
  static const maxThresholdDb = -20.0;

  double _thresholdDb;

  /// Above this is speech. THE dial.
  ///
  /// Raise it if background noise keeps a turn alive; lower it if a normal
  /// speaking voice is not picked up. The right value depends entirely on the
  /// microphone and the room, and a few dB either way is the difference
  /// between "it cannot hear me" and "the fan is talking" — which is why it
  /// is adjustable from the UI rather than only in source.
  double get thresholdDb => _thresholdDb;

  set thresholdDb(double value) =>
      _thresholdDb = value.clamp(minThresholdDb, maxThresholdDb);

  /// Quiet is [hysteresisDb] BELOW the threshold, not at it.
  ///
  /// Without a gap, audio hovering right at the bar flips between speech and
  /// silence every frame. The gap means a level has to fall clearly away
  /// before it counts as a pause.
  final double hysteresisDb;

  /// How much audio one sample represents when no duration is given.
  final Duration pollInterval;

  /// Sustained speech required before a turn starts, so one door slam does
  /// not trigger it.
  final Duration minVoiced;

  /// Quiet required to end a turn.
  ///
  /// This is the dial for "it cuts me off while I am still talking". People
  /// breathe and pause to think mid-sentence, and both read as quiet, so it
  /// has to outlast the longest gap you take without meaning to hand over.
  /// Below about two seconds it will clip you. The cost of raising it is a
  /// longer wait after you genuinely finish.
  final Duration silenceToEnd;

  bool _speechStarted = false;
  Duration _voicedFor = Duration.zero;
  Duration _quietFor = Duration.zero;

  int _sampleCount = 0;
  double _peakDb = -160;
  double _lastDb = -160;

  bool get speechStarted => _speechStarted;
  int get sampleCount => _sampleCount;
  double get peakDb => _peakDb;
  double get lastDb => _lastDb;

  /// The level speech must exceed. Constant — exposed for the level meter.
  double get triggerDb => _thresholdDb;

  /// The level at or below which audio counts as a pause.
  double get quietBelowDb => _thresholdDb - hysteresisDb;

  /// True once speech has started and then stopped for [silenceToEnd].
  bool get shouldEndTurn => _speechStarted && _quietFor >= silenceToEnd;

  /// How far through the end-of-turn pause we are, 0..1, for the UI.
  double get quietProgress {
    if (!_speechStarted || silenceToEnd.inMicroseconds == 0) return 0;
    return (_quietFor.inMicroseconds / silenceToEnd.inMicroseconds).clamp(
      0.0,
      1.0,
    );
  }

  /// Feed one level sample. [duration] is how much audio it represents.
  void addSample(double db, {Duration? duration}) {
    final step = duration ?? pollInterval;
    _sampleCount++;
    _lastDb = db;
    if (db > _peakDb) _peakDb = db;

    if (db > _thresholdDb) {
      _voicedFor += step;
      // Cleared aggressively: if you carry on talking, the quiet during that
      // breath was not a handover and must not count toward one. A shallow
      // decay lets several breaths add up across a sentence and end the turn
      // mid-thought.
      _quietFor -= step * 6;
      if (_quietFor < Duration.zero) _quietFor = Duration.zero;
      if (!_speechStarted && _voicedFor >= minVoiced) _speechStarted = true;
    } else if (db <= quietBelowDb) {
      // Voiced time decays rather than resetting, so a brief dip inside a
      // word does not throw away progress toward [minVoiced].
      _voicedFor -= step ~/ 2;
      if (_voicedFor < Duration.zero) _voicedFor = Duration.zero;
      if (_speechStarted) _quietFor += step;
    }
    // Between the two levels: hold state, change nothing.
  }

  void reset() {
    _speechStarted = false;
    _voicedFor = Duration.zero;
    _quietFor = Duration.zero;
    _sampleCount = 0;
    _peakDb = -160;
    _lastDb = -160;
  }

  /// One-line summary, used in diagnostics when a turn hears nothing.
  String describe() =>
      'level ${_lastDb.toStringAsFixed(0)} · speech above '
      '${_thresholdDb.toStringAsFixed(0)} · peak ${_peakDb.toStringAsFixed(0)} '
      'dB · $_sampleCount samples';
}
