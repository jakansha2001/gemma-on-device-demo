import 'dart:math' as math;
import 'dart:typed_data';

/// WAV <-> raw PCM helpers.
///
/// [VoiceSession] deliberately owns no microphone and no player: it takes
/// 16 kHz mono 16-bit PCM in and hands PCM back out. `package:record` gives us
/// a WAV file and `just_audio` wants a playable file, so this bridges both
/// ends. Every parser here validates before it indexes — a truncated recording
/// must raise a clear [FormatException], not a RangeError from deep inside a
/// byte loop.
abstract final class AudioConverter {
  static const _targetSampleRate = 16000;

  /// Parsed WAV payload.
  static ({Uint8List pcm, int sampleRate, int channels, int bitsPerSample})
  parseWav(Uint8List bytes) {
    if (bytes.length < 44) {
      throw const FormatException(
        'Not a WAV file: shorter than a 44-byte header',
      );
    }
    final data = ByteData.sublistView(bytes);

    String tag(int offset) =>
        String.fromCharCodes(bytes.sublist(offset, offset + 4));

    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const FormatException('Not a WAV file: missing RIFF/WAVE marker');
    }

    int? sampleRate;
    int? channels;
    int? bitsPerSample;
    Uint8List? pcm;

    // Walk the chunk list rather than assuming the canonical 44-byte layout —
    // recorders routinely insert LIST/fact chunks before `data`.
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = tag(offset);
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (size < 0 || body + size > bytes.length) {
        // Truncated final chunk: take what is actually there.
        if (id == 'data') {
          pcm = Uint8List.sublistView(bytes, body);
        }
        break;
      }
      if (id == 'fmt ' && size >= 16) {
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        pcm = Uint8List.sublistView(bytes, body, body + size);
      }
      // Chunks are word-aligned: an odd size is followed by a pad byte.
      offset = body + size + (size.isOdd ? 1 : 0);
    }

    if (sampleRate == null || channels == null || bitsPerSample == null) {
      throw const FormatException('WAV file has no fmt chunk');
    }
    if (pcm == null || pcm.isEmpty) {
      throw const FormatException('WAV file has no audio data');
    }
    if (bitsPerSample != 16) {
      throw FormatException(
        'Only 16-bit PCM is supported, got $bitsPerSample-bit',
      );
    }
    if (channels < 1) {
      throw const FormatException('WAV file reports zero channels');
    }

    return (
      pcm: pcm,
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bitsPerSample,
    );
  }

  /// Downmix to mono and resample to 16 kHz — what every STT model here wants.
  static Uint8List toPcm16kMono(
    Uint8List pcm, {
    required int sourceSampleRate,
    required int sourceChannels,
  }) {
    if (sourceSampleRate <= 0) {
      throw const FormatException('Source sample rate must be positive');
    }
    var samples = _toSamples(pcm);
    if (sourceChannels > 1) samples = _downmix(samples, sourceChannels);
    if (sourceSampleRate != _targetSampleRate) {
      samples = _resample(samples, sourceSampleRate, _targetSampleRate);
    }
    return _toBytes(samples);
  }

  /// Wrap raw PCM in a 44-byte WAV header so a player can open it.
  static Uint8List pcmToWav(
    Uint8List pcm, {
    required int sampleRate,
    int channels = 1,
    int bitsPerSample = 16,
  }) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final out = BytesBuilder();
    final header = ByteData(44);

    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // PCM fmt chunk size
    header.setUint16(20, 1, Endian.little); // format = PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);

    out.add(header.buffer.asUint8List());
    out.add(pcm);
    return out.toBytes();
  }

  /// Decode a WAV file to 16 kHz mono PCM in one call.
  ///
  /// Exists as a single static entry point so it can be handed to
  /// `compute()`. A 25-second recording is 400 000 samples, and the
  /// conversion walks them several times — on the main isolate that is a
  /// visible stall, and it happens at exactly the moment the user has just
  /// pressed stop and is watching for a response.
  static Uint8List wavToPcm16kMono(Uint8List wavBytes) {
    final wav = parseWav(wavBytes);
    return toPcm16kMono(
      wav.pcm,
      sourceSampleRate: wav.sampleRate,
      sourceChannels: wav.channels,
    );
  }

  /// Level of a PCM buffer in dBFS, for voice activity detection.
  ///
  /// Computed here rather than read from the recorder's own amplitude API.
  /// We already hold the samples, so this removes a platform dependency that
  /// is not uniformly implemented — and it stays correct on any platform
  /// where that API reports nothing.
  ///
  /// Returns [silenceDb] for an empty or digitally silent buffer, so callers
  /// never have to handle -infinity.
  static const silenceDb = -100.0;

  static double rmsDbfs(Uint8List pcm16) {
    final count = pcm16.length ~/ 2;
    if (count == 0) return silenceDb;

    final data = ByteData.sublistView(pcm16);
    var sumSquares = 0.0;
    for (var i = 0; i < count; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / count);
    if (rms <= 0) return silenceDb;
    final db = 20 * (math.log(rms) / math.ln10);
    return db < silenceDb ? silenceDb : db;
  }

  /// Duration of a raw PCM buffer, for the recording timer.
  static Duration pcmDuration(
    Uint8List pcm, {
    required int sampleRate,
    int channels = 1,
  }) {
    if (sampleRate <= 0 || channels <= 0) return Duration.zero;
    final frames = pcm.length ~/ (2 * channels);
    return Duration(microseconds: frames * 1000000 ~/ sampleRate);
  }

  // --- internals ---------------------------------------------------------

  static Int16List _toSamples(Uint8List bytes) {
    // A trailing odd byte would make the last frame garbage; drop it.
    final count = bytes.length ~/ 2;
    final out = Int16List(count);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < count; i++) {
      out[i] = data.getInt16(i * 2, Endian.little);
    }
    return out;
  }

  static Uint8List _toBytes(Int16List samples) {
    final out = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      out.setInt16(i * 2, samples[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  static Int16List _downmix(Int16List interleaved, int channels) {
    final frames = interleaved.length ~/ channels;
    final out = Int16List(frames);
    for (var f = 0; f < frames; f++) {
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        sum += interleaved[f * channels + c];
      }
      out[f] = (sum / channels).round().clamp(-32768, 32767);
    }
    return out;
  }

  /// Linear interpolation. Good enough for speech at these rates, and it
  /// avoids the aliasing that naive sample-dropping introduces.
  static Int16List _resample(Int16List input, int from, int to) {
    if (input.isEmpty) return input;
    if (from == to) return input;
    final outLength = (input.length * to / from).floor();
    if (outLength <= 0) return Int16List(0);
    final out = Int16List(outLength);
    final ratio = from / to;
    for (var i = 0; i < outLength; i++) {
      final pos = i * ratio;
      final low = pos.floor();
      final high = low + 1;
      final frac = pos - low;
      final a = input[low.clamp(0, input.length - 1)];
      final b = input[high.clamp(0, input.length - 1)];
      out[i] = (a + (b - a) * frac).round().clamp(-32768, 32767);
    }
    return out;
  }
}
