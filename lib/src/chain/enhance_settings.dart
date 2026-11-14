import '../tone/tone_balancer.dart';

/// Parameters of every step of the vocal chain; a step whose amount is 0 is skipped.
///
/// The chain runs in this order: stereo alignment → tone balance (auto-EQ) → high-pass → noise
/// reduction → EQ → de-esser → compressor → expander → loudness → limiter → (optional) silence
/// trim. Levels are in dB, frequencies in Hz, times in seconds.
///
/// The defaults are the [EnhancePreset.natural] preset.
final class EnhanceSettings {
  /// Line up the channels of a stereo take (spaced microphones) and match their levels.
  final bool alignStereo;

  /// Most the tone balance may boost a band (0 together with [toneMaxCutDb] = off).
  final double toneMaxBoostDb;

  /// Most the tone balance may cut a band.
  final double toneMaxCutDb;

  /// The long-term spectrum the tone balance aims at; `null` = [ToneCurve.balanced].
  final ToneCurve? toneCurve;

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

  /// Threshold relative to the loudness of the recording entering the compressor; above 0 only
  /// the peaks are compressed.
  final double compressionThresholdDb;

  /// Attack time of the compressor.
  final double compressionAttackSeconds;

  /// Release time of the compressor.
  final double compressionReleaseSeconds;

  /// Ratio of the expander that keeps the pauses quiet (1 = off).
  final double expanderRatio;

  /// The expander works on what is this many dB under the loudness.
  final double expanderBelowDb;

  /// Most the expander lowers anything, in dB (negative).
  final double expanderFloorDb;

  /// Integrated loudness of the result (-14 LUFS is the usual streaming level).
  final double targetLufs;

  /// Most the loudness step raises a quiet take, in dB (keeps near-silence from turning into
  /// loud noise).
  final double maxGainDb;

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
    this.alignStereo = true,
    this.toneMaxBoostDb = 12.0,
    this.toneMaxCutDb = 12.0,
    this.toneCurve,
    this.highPassHz = 80.0,
    this.noiseReductionDb = 16.0,
    this.noiseSensitivity = 1.5,
    this.noiseProfileSeconds = 0.0,
    this.mudCutDb = 0.0,
    this.mudHz = 250.0,
    this.presenceDb = 0.0,
    this.presenceHz = 3500.0,
    this.airDb = 0.0,
    this.airHz = 10000.0,
    this.deEssDb = 6.0,
    this.compressionRatio = 2.0,
    this.compressionThresholdDb = 3.0,
    this.compressionAttackSeconds = 0.01,
    this.compressionReleaseSeconds = 0.15,
    this.expanderRatio = 2.0,
    this.expanderBelowDb = 20.0,
    this.expanderFloorDb = -12.0,
    this.targetLufs = -15.0,
    this.maxGainDb = 40.0,
    this.truePeakDb = -1.0,
    this.limiterReleaseSeconds = 0.08,
    this.trimSilence = false,
    this.trimPaddingSeconds = 0.3,
  });

  /// Whether the tone balance runs.
  bool get balancesTone => toneMaxBoostDb > 0 || toneMaxCutDb > 0;

  /// A copy with the given values changed.
  EnhanceSettings copyWith({
    bool? alignStereo,
    double? toneMaxBoostDb,
    double? toneMaxCutDb,
    ToneCurve? toneCurve,
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
    double? expanderRatio,
    double? expanderBelowDb,
    double? expanderFloorDb,
    double? targetLufs,
    double? maxGainDb,
    double? truePeakDb,
    double? limiterReleaseSeconds,
    bool? trimSilence,
    double? trimPaddingSeconds,
  }) => EnhanceSettings(
    alignStereo: alignStereo ?? this.alignStereo,
    toneMaxBoostDb: toneMaxBoostDb ?? this.toneMaxBoostDb,
    toneMaxCutDb: toneMaxCutDb ?? this.toneMaxCutDb,
    toneCurve: toneCurve ?? this.toneCurve,
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
    expanderRatio: expanderRatio ?? this.expanderRatio,
    expanderBelowDb: expanderBelowDb ?? this.expanderBelowDb,
    expanderFloorDb: expanderFloorDb ?? this.expanderFloorDb,
    targetLufs: targetLufs ?? this.targetLufs,
    maxGainDb: maxGainDb ?? this.maxGainDb,
    truePeakDb: truePeakDb ?? this.truePeakDb,
    limiterReleaseSeconds: limiterReleaseSeconds ?? this.limiterReleaseSeconds,
    trimSilence: trimSilence ?? this.trimSilence,
    trimPaddingSeconds: trimPaddingSeconds ?? this.trimPaddingSeconds,
  );
}

/// Ready-made settings; any value can be changed on top of a preset with
/// [EnhanceSettings.copyWith].
enum EnhancePreset {
  /// Clean and open: balances the tone, compresses only the peaks and keeps the pauses quiet,
  /// so the room does not come up with the voice.
  natural(EnhanceSettings()),

  /// Closer and denser: stronger noise reduction and de-essing, more compression, louder.
  studio(
    EnhanceSettings(
      noiseReductionDb: 22.0,
      deEssDb: 8.0,
      compressionRatio: 3.0,
      compressionThresholdDb: 0.0,
      targetLufs: -14.0,
    ),
  ),

  /// No colouring: only the loudness and the limiter, to compare with the raw take.
  loudnessOnly(
    EnhanceSettings(
      alignStereo: false,
      toneMaxBoostDb: 0.0,
      toneMaxCutDb: 0.0,
      highPassHz: 0.0,
      noiseReductionDb: 0.0,
      deEssDb: 0.0,
      compressionRatio: 1.0,
      expanderRatio: 1.0,
      targetLufs: -14.0,
    ),
  ),

  /// The "natural" chain of version 0.1: a fixed EQ and a compressor that lifts the quiet parts.
  classic(
    EnhanceSettings(
      alignStereo: false,
      toneMaxBoostDb: 0.0,
      toneMaxCutDb: 0.0,
      mudCutDb: -2.0,
      presenceDb: 1.5,
      airDb: 2.0,
      compressionRatio: 3.0,
      compressionThresholdDb: -2.0,
      expanderRatio: 1.0,
      targetLufs: -14.0,
      maxGainDb: 30.0,
    ),
  );

  /// The settings of this preset.
  final EnhanceSettings settings;

  const EnhancePreset(this.settings);
}
