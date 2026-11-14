import 'dart:math' as math;
import 'dart:typed_data';

import '../math/numeric.dart';
import 'pcm_audio.dart';

/// Thrown when bytes are not a WAV file this codec understands.
final class WavFormatException implements Exception {
  /// What is wrong.
  final String message;

  /// Creates a new [WavFormatException].
  const WavFormatException(this.message);

  @override
  String toString() => 'WavFormatException: $message';
}

/// Decodes and encodes RIFF WAV: 8/16/24/32-bit PCM and 32/64-bit float in, 24-bit PCM out.
///
/// Decoding follows `scipy.io.wavfile.read` plus the float conversion of the reference engine:
/// unsigned 8-bit is centred on 128, signed integers are divided by 2^(bits-1), floats are kept.
abstract final class WavCodec {
  static const int _pcm = 1;
  static const int _float = 3;
  static const int _extensible = 0xFFFE;
  static const double _int24Scale = 8388608; // 1 << 23

  /// Decodes a WAV file.
  static PcmAudio decode(Uint8List bytes) {
    final ByteData data = ByteData.sublistView(bytes);
    if (bytes.length < 12 || _tag(bytes, 0) != 'RIFF' || _tag(bytes, 8) != 'WAVE') {
      throw const WavFormatException('not a RIFF WAVE file');
    }
    int? format;
    int? channels;
    int? sampleRate;
    int? bits;
    int? dataStart;
    int? dataLength;
    int offset = 12;
    while (offset + 8 <= bytes.length) {
      final String id = _tag(bytes, offset);
      final int size = data.getUint32(offset + 4, Endian.little);
      final int body = offset + 8;
      if (id == 'fmt ') {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
        if (format == _extensible && size >= 26) format = data.getUint16(body + 24, Endian.little);
      } else if (id == 'data') {
        dataStart = body;
        dataLength = math.min(size, bytes.length - body);
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    if (format == null || channels == null || sampleRate == null || bits == null) {
      throw const WavFormatException('no fmt chunk');
    }
    if (dataStart == null || dataLength == null) throw const WavFormatException('no data chunk');
    if (channels == 0) throw const WavFormatException('no channels');
    final int width = bits ~/ 8;
    if (width == 0 || bits % 8 != 0) throw WavFormatException('unsupported bit depth: $bits');
    final int frames = dataLength ~/ (width * channels);
    if (frames == 0) throw const WavFormatException('the file has no audio');
    final Samples samples = <Float64List>[for (int c = 0; c < channels; c++) Float64List(frames)];
    final double Function(int) read = _reader(data, format, bits);
    int position = dataStart;
    for (int i = 0; i < frames; i++) {
      for (int c = 0; c < channels; c++) {
        samples[c][i] = read(position);
        position += width;
      }
    }
    return PcmAudio(samples: samples, sampleRate: sampleRate);
  }

  /// Encodes [audio] as 24-bit PCM, clipping to the representable range.
  static Uint8List encode24(PcmAudio audio) {
    final int channels = audio.channels;
    final int frames = audio.frames;
    final int dataLength = frames * channels * 3;
    final Uint8List bytes = Uint8List(44 + dataLength + (dataLength.isOdd ? 1 : 0));
    final ByteData data = ByteData.sublistView(bytes);
    _setTag(bytes, 0, 'RIFF');
    data.setUint32(4, bytes.length - 8, Endian.little);
    _setTag(bytes, 8, 'WAVE');
    _setTag(bytes, 12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, _pcm, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, audio.sampleRate, Endian.little);
    data.setUint32(28, audio.sampleRate * channels * 3, Endian.little);
    data.setUint16(32, channels * 3, Endian.little);
    data.setUint16(34, 24, Endian.little);
    _setTag(bytes, 36, 'data');
    data.setUint32(40, dataLength, Endian.little);
    const double top = (_int24Scale - 1) / _int24Scale;
    int position = 44;
    for (int i = 0; i < frames; i++) {
      for (int c = 0; c < channels; c++) {
        final double value = audio.samples[c][i].clamp(-1.0, top);
        final int integer = Numeric.roundHalfEven(value * _int24Scale);
        bytes[position] = integer & 0xFF;
        bytes[position + 1] = (integer >> 8) & 0xFF;
        bytes[position + 2] = (integer >> 16) & 0xFF;
        position += 3;
      }
    }
    return bytes;
  }

  static double Function(int) _reader(ByteData data, int format, int bits) {
    if (format == _float) {
      return switch (bits) {
        32 => (int at) => data.getFloat32(at, Endian.little),
        64 => (int at) => data.getFloat64(at, Endian.little),
        _ => throw WavFormatException('unsupported float bit depth: $bits'),
      };
    }
    if (format != _pcm) throw WavFormatException('not a PCM WAV file (format $format)');
    return switch (bits) {
      8 => (int at) => (data.getUint8(at) - 128.0) / 128.0,
      16 => (int at) => data.getInt16(at, Endian.little) / 32768.0,
      24 => (int at) {
        final int raw = data.getUint8(at) | (data.getUint8(at + 1) << 8) | (data.getUint8(at + 2) << 16);
        return (raw >= 0x800000 ? raw - 0x1000000 : raw) / _int24Scale;
      },
      32 => (int at) => data.getInt32(at, Endian.little) / 2147483648.0,
      _ => throw WavFormatException('unsupported PCM bit depth: $bits'),
    };
  }

  static String _tag(Uint8List bytes, int offset) => String.fromCharCodes(bytes.sublist(offset, offset + 4));

  static void _setTag(Uint8List bytes, int offset, String tag) => bytes.setRange(offset, offset + 4, tag.codeUnits);
}
