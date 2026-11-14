import 'dart:typed_data';

/// Audio as floats in -1.0..1.0: one [Float64List] per channel, all of the same length.
typedef Samples = List<Float64List>;

/// Decoded audio: the samples of every channel and their sample rate.
final class PcmAudio {
  /// One list of samples per channel.
  final Samples samples;

  /// Samples per second.
  final int sampleRate;

  /// Creates a new [PcmAudio]; every channel must have the same length.
  PcmAudio({required this.samples, required this.sampleRate}) {
    if (samples.isEmpty) throw ArgumentError.value(samples, 'samples', 'no channels');
    if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate', 'must be positive');
    final int length = samples.first.length;
    if (samples.any((Float64List channel) => channel.length != length)) {
      throw ArgumentError.value(samples, 'samples', 'channels differ in length');
    }
  }

  /// Number of channels.
  int get channels => samples.length;

  /// Number of samples per channel.
  int get frames => samples.first.length;

  /// Length in seconds.
  double get durationSeconds => frames / sampleRate;
}

/// Helpers over [Samples].
abstract final class SampleOps {
  /// A deep copy.
  static Samples copy(Samples samples) => <Float64List>[
    for (final Float64List channel in samples) Float64List.fromList(channel),
  ];

  /// A copy multiplied by [gain].
  static Samples scaled(Samples samples, double gain) => <Float64List>[
    for (final Float64List channel in samples) SampleOps.generate(channel.length, (int i) => channel[i] * gain),
  ];

  /// A list of [length] values made by [value] (a plain loop, no boxed iterables).
  static Float64List generate(int length, double Function(int index) value) {
    final Float64List out = Float64List(length);
    for (int i = 0; i < length; i++) {
      out[i] = value(i);
    }
    return out;
  }

  /// The square of every sample averaged over the channels.
  static Float64List meanSquare(Samples samples) {
    final Float64List power = Float64List(frames(samples));
    for (final Float64List channel in samples) {
      for (int i = 0; i < power.length; i++) {
        power[i] += channel[i] * channel[i];
      }
    }
    final int channels = samples.length;
    if (channels > 1) {
      for (int i = 0; i < power.length; i++) {
        power[i] /= channels;
      }
    }
    return power;
  }

  /// Number of samples per channel.
  static int frames(Samples samples) => samples.isEmpty ? 0 : samples.first.length;
}
