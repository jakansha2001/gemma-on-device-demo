/// Cleans protocol artefacts out of the model's text channel before display.
///
/// **Why an app needs this at all.** Gemma 4 is an "SDK passthrough" model:
/// its tool calls and its reasoning both travel through the same text stream
/// as the answer, wrapped in markers the runtime is supposed to strip.
/// flutter_edge_ai does strip them — but it classifies a turn by its FIRST
/// character, so a turn shaped like
///
/// ```text
/// Task "buy milk" is done.{"role":"assistant","tool_calls":[...]}Task ...
/// ```
///
/// is classified as plain text and passed through whole, JSON and all. The
/// tool still executes correctly; this is purely what the user ends up
/// reading. The same happens with `<|channel>thought…<channel|>` reasoning
/// markers when a chat was not opened with `enableThinking: true`.
///
/// So: never trust the text channel to be clean, and sanitize the ACCUMULATED
/// buffer rather than individual tokens — a marker can be split across two
/// tokens, and a per-token filter would never see it whole.
abstract final class ModelText {
  /// Markers that carry no meaning for a reader, wherever they appear.
  static final _strayMarkers = RegExp(
    r'<\|channel\|?>|<channel\|>|<\|tool_call\|?>|<tool_call\|>|'
    r'<end_function_call>|<\|"\|>|<\|im_end\|>|<end_of_turn>',
  );

  /// A complete Gemma 4 reasoning block.
  static final _thoughtBlock = RegExp(
    r'<\|channel>thought\n?.*?<channel\|>',
    dotAll: true,
  );

  /// A reasoning block that has not closed yet, mid-stream.
  static final _openThoughtBlock = RegExp(
    r'<\|channel>thought\n?.*$',
    dotAll: true,
  );

  /// Also seen from DeepSeek/Qwen-style models.
  static final _thinkBlock = RegExp(r'<think>.*?</think>', dotAll: true);
  static final _openThinkBlock = RegExp(r'<think>.*$', dotAll: true);

  /// Anything outside Latin text, digits and ordinary punctuation.
  ///
  /// Deliberately keeps accented Latin (Latin-1 Supplement and Latin Extended-A)
  /// so "café" and "naïve" survive.
  static final _nonLatin = RegExp(r'[^\u0000-\u024F\u2010-\u203A\s]');

  /// Prepare [text] for an English speech synthesizer.
  ///
  /// Small multilingual models code-switch: a Japanese or Devanagari token can
  /// outrank the English one mid-word, producing things like "open-ソース".
  /// Lower sampling temperature makes this rare but not impossible, and an
  /// English-only synthesizer has no pronunciation for such a token — it
  /// garbles the whole phrase.
  ///
  /// So the SPOKEN text drops those characters. The displayed text keeps them:
  /// silently rewriting what the user can read would hide the model's actual
  /// output, and the point of an on-device demo is that you see what it really
  /// said.
  static String forSpeech(String text) {
    final stripped = text.replaceAll(_nonLatin, '');
    // Stripping mid-word leaves a dangling hyphen: "open-ソース" becomes
    // "open-". Only a hyphen that directly follows a word AND is followed by
    // whitespace or the end counts — a spaced dash used as punctuation
    // ("Yes — it costs") has a space on its left and is left alone.
    return stripped
        .replaceAllMapped(RegExp(r'(\w)[-–—](\s|$)'), (m) => '${m[1]}${m[2]}')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  /// Strip protocol noise from [raw].
  ///
  /// [streaming] tells it the text is still arriving, so an unterminated block
  /// is hidden rather than shown as a half-written marker. Once the turn is
  /// complete an unterminated block is a genuine truncation, and is still
  /// hidden — showing raw JSON is never the better outcome.
  static String sanitize(String raw, {bool streaming = false}) {
    if (raw.isEmpty) return raw;
    var text = raw;

    text = text.replaceAll(_thoughtBlock, '');
    text = text.replaceAll(_thinkBlock, '');
    text = _removeToolCallJson(text);

    // Whatever is left open at the end of the buffer.
    text = text.replaceAll(_openThoughtBlock, '');
    text = text.replaceAll(_openThinkBlock, '');

    text = text.replaceAll(_strayMarkers, '');

    // Collapse the blank runs the removals leave behind, without touching
    // deliberate paragraph breaks.
    text = text.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    // Leading whitespace is always an artefact; trailing is only an artefact
    // once the stream has finished (mid-stream it is the space before the
    // next token).
    return streaming ? text.trimLeft() : text.trim();
  }

  /// Remove `{"role":"assistant"...}` objects, including partial ones at the
  /// end of a stream.
  ///
  /// Brace counting rather than a regex: the payload nests several levels
  /// deep (`tool_calls[].function.arguments`), and a regex cannot match
  /// balanced braces. String literals are tracked so a `}` inside a task title
  /// does not close the object early.
  static String _removeToolCallJson(String text) {
    const marker = '{"role":';
    final buffer = StringBuffer();
    var index = 0;

    while (index < text.length) {
      final start = text.indexOf(marker, index);
      if (start == -1) {
        buffer.write(text.substring(index));
        break;
      }
      buffer.write(text.substring(index, start));

      final end = _endOfJsonObject(text, start);
      if (end == -1) {
        // Unterminated — the rest of the buffer is a partial object still
        // streaming in. Drop it; it will be re-evaluated on the next token.
        break;
      }
      index = end;
    }
    return buffer.toString();
  }

  /// Index just past the object starting at [start], or -1 if it never closes.
  static int _endOfJsonObject(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        escaped = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return -1;
  }
}
