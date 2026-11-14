/// Parameters of every step of the vocal chain; a step whose amount is 0 is skipped.
///
/// The chain runs in this order: high-pass → noise reduction → EQ → de-esser → compressor →
/// loudness → limiter → (optional) silence trim. Levels are in dB, frequencies in Hz, times in
/// seconds.
final class EnhanceSettings {
  /// Corner of the high-pass filter that removes rumble and handling noise (0 = off).
  final double highPassHz;

  /// How much the noise between the notes is lowered (0 = off).
  final double noiseReductionDb;

  /// Spreads of the noise above its median that still count as noise.
  final double noiseSensitivity;

  /// Leading seconds of room tone used as the noise profile (0 = find the quietest parts).
  final double noiseProfileSeconds;

  /// Peaking EQ at [mudHz]; a negative value removes boominess.
  final double mudCutDb;

  /// Centre of the mud band.
  final double mudHz;

  /// Peaking EQ at [presenceHz]; makes the words clearer.
  final double presenceDb;

  /// Centre of the presence band.
  final double presenceHz;

  /// High shelf at [airHz]; adds air and sparkle.
  final double airDb;

  /// Corner of the air shelf.
  final double airHz;

  /// Most the sibilance band (5-9 kHz) is lowered on "s" and "sh" (0 = off).
  final double deEssDb;

  /// Ratio of the compressor (1 = off).
  final double compressionRatio;

  /// Threshold relative to the loudness of the recording entering the compressor.
  final double compressionThresholdDb;

  /// Attack time of the compressor.
  final double compressionAttackSeconds;

  /// Release time of the compressor.
  final double compressionReleaseSeconds;

  /// Integrated loudness of the result (-14 LUFS is the usual streaming level).
  final double targetLufs;

  /// Ceiling of the limiter in dBTP.
  final double truePeakDb;

  /// Release time of the limiter.
  final double limiterReleaseSeconds;

  /// Cut the silence before the first and after the last sung note.
  final bool trimSilence;

  /// Silence kept before and after the singing when trimming.
  final double trimPaddingSeconds;

  /// Creates new [EnhanceSettings]; the defaults are the "natural" preset.
  const EnhanceSettings({
    this.highPassHz = 80.0,
    this.noiseReductionDb = 16.0,
    this.noiseSensitivity = 1.5,
    this.noiseProfileSeconds = 0.0,
    this.mudCutDb = -2.0,
    this.mudHz = 250.0,
    this.presenceDb = 1.5,
    this.presenceHz = 3500.0,
    this.airDb = 2.0,
    this.airHz = 10000.0,
    this.deEssDb = 6.0,
    this.compressionRatio = 3.0,
    this.compressionThresholdDb = -2.0,
    this.compressionAttackSeconds = 0.01,
    this.compressionReleaseSeconds = 0.15,
    this.targetLufs = -14.0,
    this.truePeakDb = -1.0,
    this.limiterReleaseSeconds = 0.08,
    this.trimSilence = false,
    this.trimPaddingSeconds = 0.3,
  });

  /// A copy with the given values changed.
  EnhanceSettings copyWith({
    double? highPassHz,
    double? noiseReductionDb,
    double? noiseSensitivity,
    double? noiseProfileSeconds,
    double? mudCutDb,
    double? mudHz,
    double? presenceDb,
    double? presenceHz,
    double? airDb,
    double? airHz,
    double? deEssDb,
    double? compressionRatio,
    double? compressionThresholdDb,
    double? compressionAttackSeconds,
    double? compressionReleaseSeconds,
    double? targetLufs,
    double? truePeakDb,
    double? limiterReleaseSeconds,
    bool? trimSilence,
    double? trimPaddingSeconds,
  }) => EnhanceSettings(
    highPassHz: highPassHz ?? this.highPassHz,
    noiseReductionDb: noiseReductionDb ?? this.noiseReductionDb,
    noiseSensitivity: noiseSensitivity ?? this.noiseSensitivity,
    noiseProfileSeconds: noiseProfileSeconds ?? this.noiseProfileSeconds,
    mudCutDb: mudCutDb ?? this.mudCutDb,
    mudHz: mudHz ?? this.mudHz,
    presenceDb: presenceDb ?? this.presenceDb,
    presenceHz: presenceHz ?? this.presenceHz,
    airDb: airDb ?? this.airDb,
    airHz: airHz ?? this.airHz,
    deEssDb: deEssDb ?? this.deEssDb,
    compressionRatio: compressionRatio ?? this.compressionRatio,
    compressionThresholdDb: compressionThresholdDb ?? this.compressionThresholdDb,
    compressionAttackSeconds: compressionAttackSeconds ?? this.compressionAttackSeconds,
    compressionReleaseSeconds: compressionReleaseSeconds ?? this.compressionReleaseSeconds,
    targetLufs: targetLufs ?? this.targetLufs,
    truePeakDb: truePeakDb ?? this.truePeakDb,
    limiterReleaseSeconds: limiterReleaseSeconds ?? this.limiterReleaseSeconds,
    trimSilence: trimSilence ?? this.trimSilence,
    trimPaddingSeconds: trimPaddingSeconds ?? this.trimPaddingSeconds,
  );
}

/// Ready-made settings; any value can be changed on top of a preset with
/// [EnhanceSettings.copyWith].
enum EnhancePreset {
  /// Gentle cleanup: keeps the room and the dynamics, removes rumble and steady noise.
  natural(EnhanceSettings()),

  /// Close and polished: stronger noise reduction, more presence, tighter compression.
  studio(
    EnhanceSettings(
      noiseReductionDb: 22.0,
      mudCutDb: -3.0,
      presenceDb: 2.5,
      airDb: 3.0,
      deEssDb: 8.0,
      compressionRatio: 4.0,
      compressionThresholdDb: -4.0,
    ),
  ),

  /// No colouring: only the loudness and the limiter, to compare with the raw take.
  loudnessOnly(
    EnhanceSettings(
      highPassHz: 0.0,
      noiseReductionDb: 0.0,
      mudCutDb: 0.0,
      presenceDb: 0.0,
      airDb: 0.0,
      deEssDb: 0.0,
      compressionRatio: 1.0,
    ),
  );

  /// The settings of this preset.
  final EnhanceSettings settings;

  const EnhancePreset(this.settings);
}
