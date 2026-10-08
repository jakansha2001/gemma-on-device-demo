/// Splits a streaming reply into speakable sentences.
///
/// **Why this exists.** `SpeechSynthesizer.synthesize` is batch: full text in,
/// full audio out. So the obvious pipeline — generate the whole reply, then
/// synthesize it — cannot start speaking until the last token has arrived.
/// On a phone that is several seconds of silence while the finished text sits
/// on screen, which is exactly backwards from how a voice assistant should
/// feel.
///
/// Feeding the synthesizer one sentence at a time lets audio start after the
/// FIRST sentence instead of the last. This class does the splitting: push
/// tokens in, pull complete sentences out.
///
/// Splitting is deliberately conservative. A false split mid-sentence makes
/// the synthesizer put a full stop where the speaker would not, which sounds
/// worse than waiting slightly longer — so abbreviations, decimals and
/// ellipses are all held back.
class SentenceChunker {
  final StringBuffer _pending = StringBuffer();

  /// Below this, a "sentence" is usually an abbreviation or a stray bullet —
  /// speaking it alone sounds clipped, so it is merged into the next one.
  static const _minSentenceLength = 12;

  /// Past this, emit at the next breath (comma, colon, dash) even without
  /// terminal punctuation — a model that never punctuates must not mean the
  /// user hears nothing at all.
  static const _softLimit = 160;

  /// A hard ceiling, so an unpunctuated monologue still produces audio.
  static const _hardLimit = 240;

  static const _terminators = {'.', '!', '?', '\n'};
  static const _breathMarks = {',', ';', ':', '—', '–'};

  /// Titles and abbreviations whose full stop does not end a sentence.
  static const _abbreviations = {
    'mr',
    'mrs',
    'ms',
    'dr',
    'prof',
    'sr',
    'jr',
    'st',
    'e.g',
    'i.e',
    'etc',
    'vs',
    'approx',
    'no',
    'fig',
  };

  /// Push a streamed token. Returns any sentences that are now complete.
  List<String> add(String token) {
    _pending.write(token);
    final out = <String>[];
    while (true) {
      final sentence = _extract();
      if (sentence == null) break;
      out.add(sentence);
    }
    return out;
  }

  /// Whatever is left when generation ends. Call once, at the end.
  String? flush() {
    final rest = _clean(_pending.toString());
    _pending.clear();
    return rest.isEmpty ? null : rest;
  }

  String? _extract() {
    final text = _pending.toString();
    if (text.isEmpty) return null;

    final cut = _findCut(text);
    if (cut == null) return null;

    final head = text.substring(0, cut);
    final tail = text.substring(cut);
    _pending
      ..clear()
      ..write(tail);

    final cleaned = _clean(head);
    // An empty chunk (a lone newline, say) should not stall the loop.
    return cleaned.isEmpty ? _extract() : cleaned;
  }

  /// Index just past the end of the first complete sentence, or null.
  int? _findCut(String text) {
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];

      if (_terminators.contains(ch)) {
        if (ch == '.' && !_isRealFullStop(text, i)) continue;

        // A newline is a STRUCTURAL break — a heading or list item. Emit it
        // on its own even when short, because merging it into the next
        // sentence runs two separate ideas together.
        final structural = ch == '\n';

        // Absorb trailing quotes/brackets and run-on punctuation ("?!").
        var end = i + 1;
        while (end < text.length && '")]}\'!?.'.contains(text[end])) {
          end++;
        }

        // If the absorb ran to the end of the buffer we cannot tell whether
        // more punctuation is still streaming in — "that?" might become
        // "that?!". Wait for the next token rather than splitting early.
        if (!structural && end >= text.length) return null;

        if (!structural &&
            _clean(text.substring(0, end)).length < _minSentenceLength) {
          continue;
        }
        return end;
      }

      // Soft limit: break at a breath mark rather than mid-word.
      if (i >= _softLimit && _breathMarks.contains(ch)) return i + 1;
    }

    // Hard limit: break at the last word boundary we can find.
    if (text.length >= _hardLimit) {
      final space = text.lastIndexOf(' ', _hardLimit);
      return space > _minSentenceLength ? space + 1 : _hardLimit;
    }
    return null;
  }

  /// A '.' only ends a sentence if it is not a decimal point, an ellipsis, an
  /// abbreviation, or an initial.
  bool _isRealFullStop(String text, int i) {
    final before = i > 0 ? text[i - 1] : '';
    final after = i + 1 < text.length ? text[i + 1] : '';

    // 3.14 — a decimal point.
    if (_isDigit(before) && _isDigit(after)) return false;
    // "..." — wait for the last one.
    if (after == '.') return false;
    // Mid-stream: we cannot yet tell "Dr." from the end of a sentence, so
    // require the next character to have arrived.
    if (after.isEmpty) return false;
    // A single capital before the dot is an initial: "J. Smith".
    if (i >= 1 && _isUpper(before) && (i < 2 || !_isLetter(text[i - 2]))) {
      return false;
    }

    final word = _lastWord(text.substring(0, i));
    return !_abbreviations.contains(word);
  }

  static String _lastWord(String text) {
    final match = RegExp(r'[A-Za-z.]+$').firstMatch(text);
    return match?.group(0)?.toLowerCase() ?? '';
  }

  /// Strip markdown that the synthesizer would otherwise read aloud as
  /// literal punctuation ("star star bold star star").
  static String _clean(String text) => text
      .replaceAll(RegExp(r'\*\*|__|`{1,3}|~~'), '')
      .replaceAll(RegExp(r'^\s*[#>]+\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _isDigit(String c) =>
      c.isNotEmpty && c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
  static bool _isUpper(String c) =>
      c.isNotEmpty && c.codeUnitAt(0) >= 0x41 && c.codeUnitAt(0) <= 0x5A;
  static bool _isLetter(String c) =>
      c.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(c);
}
