/// Levels of one recording and the problems they reveal.
final class RecordingAnalysis {
  static const double _clippedPercent = 0.01;
  static const double _quietPeakDb = -18.0;
  static const double _noisySnrDb = 30.0;

  /// Length in seconds.
  final double durationSeconds;

  /// Samples per second.
  final int sampleRate;

  /// Number of channels.
  final int channels;

  /// Integrated loudness (ITU-R BS.1770) in LUFS; `-infinity` for silence.
  final double integratedLufs;

  /// Highest inter-sample peak in dBTP.
  final double truePeakDb;

  /// Share of the samples at full scale, in percent.
  final double clippedPercent;

  /// Level of the quietest parts (10th percentile of 50 ms blocks), in dBFS.
  final double noiseFloorDb;

  /// Loud parts (90th percentile) above the noise floor, in dB.
  final double signalToNoiseDb;

  /// Creates a new [RecordingAnalysis].
  const RecordingAnalysis({
    required this.durationSeconds,
    required this.sampleRate,
    required this.channels,
    required this.integratedLufs,
    required this.truePeakDb,
    required this.clippedPercent,
    required this.noiseFloorDb,
    required this.signalToNoiseDb,
  });

  /// True when the input level was too high and the peaks were cut off.
  bool get isClipped => clippedPercent > _clippedPercent;

  /// True when the input level was so low that the noise will be raised with the voice.
  bool get isTooQuiet => truePeakDb < _quietPeakDb;

  /// True when the room noise is close to the voice.
  bool get isNoisy => signalToNoiseDb < _noisySnrDb;

  @override
  String toString() =>
      'RecordingAnalysis(${durationSeconds.toStringAsFixed(2)} s, $sampleRate Hz, '
      '$channels ch, ${integratedLufs.toStringAsFixed(1)} LUFS, ${truePeakDb.toStringAsFixed(1)} dBTP, '
      'clipped ${clippedPercent.toStringAsFixed(3)} %, noise ${noiseFloorDb.toStringAsFixed(1)} dBFS, '
      'SNR ${signalToNoiseDb.toStringAsFixed(1)} dB)';
}
